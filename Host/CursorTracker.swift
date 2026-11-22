import AppKit
import Shared

/// Polls the host cursor position (120 Hz) and shape (10 Hz) and reports changes.
final class CursorTracker {
    private var posTimer: Timer?, shapeTimer: Timer?
    private var lastPos: (Float32, Float32)?
    private var lastShapeKey: Int?
    private(set) var currentShape: CursorShape?

    var onPosition: ((Float32, Float32) -> Void)?
    var onShape: ((CursorShape) -> Void)?

    func start() {
        posTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.pollPosition() }
        shapeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollShape() }
        RunLoop.main.add(posTimer!, forMode: .common)
        RunLoop.main.add(shapeTimer!, forMode: .common)
        pollShape()
    }

    func stop() { posTimer?.invalidate(); shapeTimer?.invalidate() }

    /// Forces the next poll to resend position (e.g. when a client connects).
    func resend() { lastPos = nil; if let s = currentShape { onShape?(s) } }

    private func pollPosition() {
        guard let screen = NSScreen.screens.first else { return }
        let p = NSEvent.mouseLocation
        let f = screen.frame
        let pos = (Float32((p.x - f.minX) / f.width), Float32((f.maxY - p.y) / f.height))
        if let l = lastPos, abs(l.0 - pos.0) < 1e-5, abs(l.1 - pos.1) < 1e-5 { return }
        lastPos = pos
        onPosition?(pos.0, pos.1)
    }

    private func pollShape() {
        guard let cursor = NSCursor.currentSystem, let screen = NSScreen.screens.first else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let key = tiff.hashValue ^ Int(cursor.hotSpot.x * 1000) ^ Int(cursor.hotSpot.y * 7919)
        if key == lastShapeKey { return }
        lastShapeKey = key
        guard let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]),
              png.count < WireProtocol.maxControlMessage - 64 else { return }
        let size = image.size, dw = screen.frame.width
        let shape = CursorShape(width: Float32(size.width / dw), height: Float32(size.height / dw),
                                hotX: Float32(cursor.hotSpot.x / size.width), hotY: Float32(cursor.hotSpot.y / size.height),
                                png: png)
        currentShape = shape
        onShape?(shape)
    }
}
