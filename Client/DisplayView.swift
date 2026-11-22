import AppKit
import AVFoundation
import CoreImage

/// Full-screen borderless window showing decoded frames, aspect-fit.
final class DisplayWindow {
    let window: NSWindow
    let layer = AVSampleBufferDisplayLayer()
    private var lastFrame: CVPixelBuffer?
    private let lock = NSLock()

    init(windowed: Bool) {
        let screen = NSScreen.main!
        let rect = windowed ? NSRect(x: 100, y: 100, width: 960, height: 600) : screen.frame
        window = NSWindow(contentRect: rect, styleMask: windowed ? [.titled] : [.borderless],
                          backing: .buffered, defer: false, screen: screen)
        window.title = "RemoteMirror"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        if !windowed { window.level = .mainMenu + 1 }
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        window.contentView = view
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSCursor.hide()
    }

    func close() { NSCursor.unhide(); window.orderOut(nil) }

    /// Enqueues a decoded frame for immediate display.
    func display(_ pb: CVPixelBuffer) {
        lock.lock(); lastFrame = pb; lock.unlock()
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

    /// Writes the most recently displayed frame as PNG. Returns false if none yet.
    func dumpFrame(to path: String) -> Bool {
        lock.lock(); let pb = lastFrame; lock.unlock()
        guard let pb else { return false }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        do {
            try ctx.writePNGRepresentation(of: ci, to: URL(fileURLWithPath: path), format: .RGBA8, colorSpace: cs)
            return true
        } catch { return false }
    }
}
