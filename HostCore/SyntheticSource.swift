import CoreMedia
import CoreVideo
import Foundation

/// Generates moving NV12 frames at a fixed rate; stands in for screen capture
/// when Screen Recording isn't granted (tests, transport work).
public final class SyntheticSource {
    public let width: Int, height: Int
    private let fps: Int32
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var n: Int64 = 0

    public init(width: Int = 1440, height: Int = 900, fps: Int32) {
        self.width = width; self.height = height; self.fps = fps
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    public func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "synthetic", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in
            guard let self, let pb = self.makeFrame() else { return }
            onFrame(pb, CMTime(value: self.n, timescale: self.fps))
            self.n += 1
        }
        timer = t
        t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    private func makeFrame() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        // Horizontal bands that scroll every frame: cheap to generate, never static.
        for row in 0..<height { memset(y + row * stride, Int32(truncatingIfNeeded: (row / 8 + Int(n) * 3) & 0xff), width) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
