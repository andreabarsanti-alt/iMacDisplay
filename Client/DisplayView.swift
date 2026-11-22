import AppKit
import AVFoundation
import CoreImage
import ImageIO
import Shared

/// Borderless windows can't become key by default; this one must, to get keystrokes.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen borderless window showing decoded frames, aspect-fit.
final class DisplayWindow {
    let window: NSWindow
    let layer = AVSampleBufferDisplayLayer()
    private(set) var inputView: InputView!
    /// Cursor drawn locally on top of the video (M7).
    let cursorLayer = CALayer()
    private var cursorShape: CursorShape?
    private var cursorPos: (Float32, Float32) = (0.5, 0.5)
    private var lastLocalMove = Date.distantPast
    private(set) var cursorUpdates = 0
    private var lastFrame: CVPixelBuffer?
    private let lock = NSLock()

    init(windowed: Bool) {
        let screen = NSScreen.main!
        let rect = windowed ? NSRect(x: 100, y: 100, width: 960, height: 600) : screen.frame
        window = KeyWindow(contentRect: rect, styleMask: windowed ? [.titled] : [.borderless],
                          backing: .buffered, defer: false, screen: screen)
        window.title = "RemoteMirror"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        if !windowed { window.level = .mainMenu + 1 }
        let view = InputView(frame: NSRect(origin: .zero, size: rect.size))
        inputView = view
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        view.layer?.addSublayer(cursorLayer)
        window.contentView = view
        view.onLocalMove = { [weak self] x, y in self?.localCursor(x, y) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputView)
        NSCursor.hide()
    }

    func close() { NSCursor.unhide(); window.orderOut(nil) }

    /// Pause: hide the mirror and give the iMac back (connection stays up).
    func hide() {
        NSCursor.unhide()
        window.orderOut(nil)
        NSApp.hide(nil)
    }

    /// Enqueues a decoded frame for immediate display.
    func display(_ pb: CVPixelBuffer) {
        lock.lock(); lastFrame = pb; lock.unlock()
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        if inputView.videoSize != size { inputView.videoSize = size }
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

    // MARK: Cursor overlay

    func setCursorShape(_ shape: CursorShape) {
        cursorShape = shape
        if let src = CGImageSourceCreateWithData(shape.png as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            cursorLayer.contents = img
        }
        layoutCursor()
    }

    /// Host-reported position: used unless the iMac's own mouse moved very recently
    /// (then the local position is already shown, with zero lag).
    func hostCursor(_ x: Float32, _ y: Float32, visible: Bool) {
        cursorUpdates += 1
        guard Date().timeIntervalSince(lastLocalMove) > 0.25 else { return }
        cursorPos = (x, y)
        layoutCursor()
    }

    private func localCursor(_ x: Float32, _ y: Float32) {
        lastLocalMove = Date()
        cursorPos = (x, y)
        layoutCursor()
    }

    private func layoutCursor() {
        guard let shape = cursorShape else { return }
        let r = inputView.videoRect
        let w = CGFloat(shape.width) * r.width, h = CGFloat(shape.height) * r.width
        let p = inputView.viewPoint(nx: Double(cursorPos.0), ny: Double(cursorPos.1))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Place the image so its hotspot sits on the pointer position (layer coords are bottom-up).
        cursorLayer.frame = CGRect(x: p.x - CGFloat(shape.hotX) * w, y: p.y - (1 - CGFloat(shape.hotY)) * h, width: w, height: h)
        cursorLayer.isHidden = false
        CATransaction.commit()
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
