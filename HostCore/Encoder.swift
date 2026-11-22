import CoreMedia
import Foundation
import Shared
import VideoToolbox

/// Hardware H.264/HEVC encoder producing Annex B access units
/// (parameter sets prepended to every keyframe).
public final class VideoEncoder {
    public struct Output {
        public let annexB: Data
        public let isKeyframe: Bool
        public let ptsNanos: UInt64
        public let encodeNanos: UInt64
    }

    public enum EncoderError: Error, CustomStringConvertible {
        case create(OSStatus), property(String, OSStatus)
        public var description: String {
            switch self {
            case let .create(s): return "VTCompressionSessionCreate failed (\(s))"
            case let .property(k, s): return "setting \(k) failed (\(s))"
            }
        }
    }

    public let width: Int32, height: Int32, codec: CMVideoCodecType
    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private let lock = NSLock()
    private let onOutput: (Output) -> Void
    private var submitTimes: [Int64: UInt64] = [:]   // pts value -> submit time

    public private(set) var usingHardware = false

    public init(width: Int32, height: Int32, fps: Int32, bitrate: Int, codec: CMVideoCodecType = kCMVideoCodecType_H264,
         onOutput: @escaping (Output) -> Void) throws {
        self.width = width; self.height = height; self.codec = codec; self.onOutput = onOutput
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: codec,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                            compressionSessionOut: &s)
        guard st == noErr, let s else { throw EncoderError.create(st) }
        session = s

        func set(_ key: CFString, _ value: Any) throws {
            let r = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
            if r != noErr { throw EncoderError.property(key as String, r) }
        }
        try set(kVTCompressionPropertyKey_RealTime, true)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        try set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // DataRateLimits: [bytes, seconds] -> cap at 1.5x the average over 1 s.
        try set(kVTCompressionPropertyKey_DataRateLimits, [Int(Double(bitrate) * 1.5 / 8), 1] as CFArray)
        // Tag colour in the bitstream (VUI) so the decoder output carries it.
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 60)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        if codec == kCMVideoCodecType_H264 {
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        } else {
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)

        var hw: CFTypeRef?
        let hwStatus = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0)
        }
        if hwStatus == noErr {
            usingHardware = (hw as? Bool) ?? false
        }
    }

    deinit { invalidate() }

    public func invalidate() {
        lock.lock(); let s = session; session = nil; lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    public func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard let s = session else { lock.unlock(); return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        let submitted = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            let encodeNanos = DispatchTime.now().uptimeNanoseconds - submitted
            self.emit(sample, encodeNanos: encodeNanos)
        }
    }

    private func emit(_ sample: CMSampleBuffer, encodeNanos: UInt64) {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey {
            for ps in Self.parameterSets(format, codec: codec) {
                out.append(contentsOf: startCode); out.append(ps)
            }
        }
        // AVCC/HVCC (4-byte big-endian lengths) -> Annex B start codes.
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr else { return }
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= length {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = UInt32(bigEndian: nalLen)
            offset += 4
            guard offset + Int(nalLen) <= length else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ptsNanos = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1e9)) : 0
        onOutput(Output(annexB: out, isKeyframe: isKey, ptsNanos: ptsNanos, encodeNanos: encodeNanos))
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: CMVideoCodecType) -> [Data] {
        var sets: [Data] = []
        var count = 0
        let isHEVC = codec == kCMVideoCodecType_HEVC
        func get(_ i: Int, _ ptr: inout UnsafePointer<UInt8>?, _ size: inout Int, _ cnt: UnsafeMutablePointer<Int>?) -> OSStatus {
            isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: cnt, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: cnt, nalUnitHeaderLengthOut: nil)
        }
        var p: UnsafePointer<UInt8>?; var sz = 0
        guard get(0, &p, &sz, &count) == noErr else { return [] }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            if get(i, &ptr, &size, nil) == noErr, let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets
    }
}
