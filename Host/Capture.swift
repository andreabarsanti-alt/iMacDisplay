import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the main display with ScreenCaptureKit and hands complete frames to `onFrame`.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let onError: (String) -> Void
    private(set) var width = 0, height = 0

    init(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void, onError: @escaping (String) -> Void) {
        self.onFrame = onFrame; self.onError = onError
    }

    /// Picks the main display; size is the display's point size (not Retina pixels), forced even.
    func start(fps: Int32, maxWidth: Int? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        var w = display.width, h = display.height
        if let maxWidth, w > maxWidth { h = h * maxWidth / w; w = maxWidth }
        width = w & ~1; height = h & ~1

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false          // the client draws the cursor (Phase 3)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,   // idle/blank frames carry no new image
              let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        onFrame(pb, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError("capture stopped: \(error.localizedDescription)")
    }
}
