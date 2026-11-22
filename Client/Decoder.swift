import CoreMedia
import Foundation
import VideoToolbox

/// Annex B H.264/HEVC -> CVPixelBuffer using the iMac's hardware decoder.
final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var paramSets: [Data] = []   // current VPS/SPS/PPS
    private let onFrame: (CVPixelBuffer, CMTime, UInt64) -> Void   // buffer, pts, decode nanos
    var onError: ((String) -> Void)?
    private(set) var usingHardware = false

    init(onFrame: @escaping (CVPixelBuffer, CMTime, UInt64) -> Void) { self.onFrame = onFrame }

    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    /// Returns false if the frame couldn't be decoded (caller should request a keyframe).
    @discardableResult
    func decode(annexB: Data, ptsNanos: UInt64, hevc: Bool) -> Bool {
        let nals = Self.splitAnnexB(annexB)
        var newParams: [Data] = [], slices: [Data] = []
        for nal in nals {
            guard let first = nal.first else { continue }
            let isParam = hevc ? (32...34).contains((first >> 1) & 0x3f) : [7, 8].contains(first & 0x1f)
            if isParam { newParams.append(nal) } else { slices.append(nal) }
        }
        if !newParams.isEmpty, newParams != paramSets {
            paramSets = newParams
            guard makeFormat(hevc: hevc) else { return false }
        }
        guard let format, let session, !slices.isEmpty else { return session != nil && slices.isEmpty }

        // Annex B -> length-prefixed (AVCC/HVCC) sample.
        var avcc = Data()
        for s in slices {
            var len = UInt32(s.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(s)
        }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return false }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                 offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(ptsNanos), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return false }

        let start = DispatchTime.now().uptimeNanoseconds
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, pts, _ in
            guard let self else { return }
            guard status == noErr, let image else { self.onError?("decode status \(status)"); return }
            self.onFrame(image, pts, DispatchTime.now().uptimeNanoseconds - start)
        }
        return st == noErr
    }

    private func makeFormat(hevc: Bool) -> Bool {
        var fmt: CMVideoFormatDescription?
        let ptrs = paramSets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let sizes = paramSets.map(\.count)
        let pointers = ptrs.map { UnsafePointer($0) }
        let st = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                  parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        guard st == noErr, let fmt else { onError?("format description \(st)"); return false }
        if session != nil, let format, CMFormatDescriptionEqual(format, otherFormatDescription: fmt) { return true }
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        format = fmt

        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                             decompressionSessionOut: &s)
        guard r == noErr, let s else { onError?("decoder create \(r)"); return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: CFTypeRef?
        let hwStatus = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0)
        }
        if hwStatus == noErr {
            usingHardware = (hw as? Bool) ?? false
        }
        session = s
        return true
    }

    /// Splits on 3- or 4-byte start codes.
    static func splitAnnexB(_ d: Data) -> [Data] {
        var out: [Data] = []
        let b = [UInt8](d)
        var i = 0, start = -1
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, b[end - 1] == 0 { end -= 1 }   // 4-byte start code
                    out.append(Data(b[start..<end]))
                }
                i += 3; start = i
            } else { i += 1 }
        }
        if start >= 0, start < b.count { out.append(Data(b[start...])) }
        return out
    }
}
