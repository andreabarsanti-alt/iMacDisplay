import AppKit
import Shared

/// Polls the host cursor position (120 Hz) and shape (10 Hz) and reports changes.
public final class CursorTracker {
    private var posTimer: Timer?, shapeTimer: Timer?
    private var lastPos: (Float32, Float32)?
    private var lastShapeKey: Int?
    private var lastInside = true
    public private(set) var currentShape: CursorShape?

    /// The display being shared; positions are normalized to it and the cursor is
    /// reported hidden while it is on another display.
    public var displayID: CGDirectDisplayID = CGMainDisplayID() { didSet { lastPos = nil; lastShapeKey = nil } }
    public var onPosition: ((Float32, Float32) -> Void)?
    public var onVisibility: ((Float32, Float32, Bool) -> Void)?
    public var onShape: ((CursorShape) -> Void)?

    public func start() {
        posTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.pollPosition() }
        shapeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollShape() }
        RunLoop.main.add(posTimer!, forMode: .common)
        RunLoop.main.add(shapeTimer!, forMode: .common)
        pollShape()
    }

    public func stop() { posTimer?.invalidate(); shapeTimer?.invalidate() }

    /// Forces the next poll to resend position (e.g. when a client connects).
    public func resend() { lastPos = nil; if let s = currentShape { onShape?(s) } }

    private func pollPosition() {
        // Global top-left coordinates, same space as CGDisplayBounds.
        guard let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0 else { return }
        let inside = b.contains(loc)
        let pos = (Float32((loc.x - b.minX) / b.width), Float32((loc.y - b.minY) / b.height))
        if let l = lastPos, abs(l.0 - pos.0) < 1e-5, abs(l.1 - pos.1) < 1e-5, inside == lastInside { return }
        lastPos = pos
        if inside != lastInside { lastInside = inside; onVisibility?(pos.0, pos.1, inside) }
        if inside { onPosition?(pos.0, pos.1) }
    }

    private func pollShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let key = tiff.hashValue ^ Int(cursor.hotSpot.x * 1000) ^ Int(cursor.hotSpot.y * 7919)
        if key == lastShapeKey { return }
        lastShapeKey = key
        guard let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]),
              png.count < WireProtocol.maxControlMessage - 64 else { return }
        let size = image.size, dw = CGDisplayBounds(displayID).width
        let shape = CursorShape(width: Float32(size.width / dw), height: Float32(size.height / dw),
                                hotX: Float32(cursor.hotSpot.x / size.width), hotY: Float32(cursor.hotSpot.y / size.height),
                                png: png)
        currentShape = shape
        onShape?(shape)
    }
}
