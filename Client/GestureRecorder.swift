import AppKit
import ApplicationServices

/// Diagnostic (--record-gestures): logs every event the iMac's window server delivers
/// (listen-only tap: nothing is changed or swallowed), with the fields that matter for
/// Magic Mouse gestures. Event types 29 (gesture), 30 (dock control), 31 (fluid touch)
/// are undocumented; for those every non-zero field 0-255 is printed.
final class GestureRecorder {
    private var tap: CFMachPort?
    private var count = 0

    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask.max,
                                        callback: { _, type, event, refcon in
                                            Unmanaged<GestureRecorder>.fromOpaque(refcon!).takeUnretainedValue().log(type, event)
                                            return Unmanaged.passUnretained(event)
                                        }, userInfo: refcon) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func log(_ type: CGEventType, _ e: CGEvent) {
        let raw = type.rawValue
        // Skip plain pointer motion to keep the log readable.
        if raw == CGEventType.mouseMoved.rawValue { return }
        count += 1
        var line = "{\"event\":\"rec\",\"n\":\(count),\"type\":\(raw)"
        if raw == CGEventType.scrollWheel.rawValue {
            func i(_ f: CGEventField) -> Int64 { e.getIntegerValueField(f) }
            func d(_ f: CGEventField) -> Double { e.getDoubleValueField(f) }
            line += ",\"phase\":\(i(.scrollWheelEventScrollPhase)),\"momentum\":\(i(.scrollWheelEventMomentumPhase))"
            line += ",\"continuous\":\(i(.scrollWheelEventIsContinuous))"
            line += String(format: ",\"fx\":%.3f,\"fy\":%.3f,\"px\":%lld,\"py\":%lld",
                           d(.scrollWheelEventFixedPtDeltaAxis2), d(.scrollWheelEventFixedPtDeltaAxis1),
                           i(.scrollWheelEventPointDeltaAxis2), i(.scrollWheelEventPointDeltaAxis1))
        } else if ![1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 25, 26, 27].contains(raw) {
            var fields: [String] = []
            for f in 0...255 {
                guard let field = CGEventField(rawValue: UInt32(f)) else { continue }
                let iv = e.getIntegerValueField(field)
                let dv = e.getDoubleValueField(field)
                if iv != 0 || dv != 0 { fields.append(String(format: "\"%d\":[%lld,%.4f]", f, iv, dv)) }
            }
            line += ",\"fields\":{\(fields.joined(separator: ","))}"
        }
        print(line + "}")
    }
}
