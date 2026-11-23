import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac (and its display) from idling while a session runs, like a video
/// call does. Without it the MacBook falls asleep after its idle timeout (1 min here)
/// whenever nobody touches the iMac's keyboard/mouse, which ends the session.
/// Deliberate sleep (lid closed, Apple menu > Sleep) and locking the screen on
/// purpose are not prevented.
public final class PowerAssertion {
    private var ids: [IOPMAssertionID] = []
    public private(set) var isHeld = false

    public init() {}
    deinit { release() }

    /// - Parameter system: also prevent idle *system* sleep (the MacBook side).
    public func hold(reason: String, system: Bool) {
        guard !isHeld else { return }
        var types = [kIOPMAssertionTypePreventUserIdleDisplaySleep]
        if system { types.append(kIOPMAssertionTypePreventUserIdleSystemSleep) }
        for t in types {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason as CFString, &id) == kIOReturnSuccess {
                ids.append(id)
            }
        }
        isHeld = !ids.isEmpty
    }

    public func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
        isHeld = false
    }
}
