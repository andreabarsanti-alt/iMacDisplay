import Testing
@testable import HostCore

@Suite struct DisplayPolicyTests {
    let builtin = DisplayInfo(id: 1, isBuiltin: true, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964)
    let dummy = DisplayInfo(id: 7, isBuiltin: false, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880)

    @Test func automaticPrefersExternal() {
        #expect(Displays.choose([builtin, dummy], .automatic) == dummy)
        #expect(Displays.choose([dummy, builtin], .automatic) == dummy)
    }
    @Test func automaticFallsBackToBuiltin() { #expect(Displays.choose([builtin], .automatic) == builtin) }
    @Test func lidClosedLeavesOnlyExternal() {
        // Lid closed: the built-in display disappears; every choice lands on the dummy.
        for c in DisplayChoice.allCases { #expect(Displays.choose([dummy], c) == dummy) }
    }
    @Test func explicitChoices() {
        #expect(Displays.choose([builtin, dummy], .builtin) == builtin)
        #expect(Displays.choose([builtin, dummy], .external) == dummy)
        #expect(Displays.choose([builtin], .external) == builtin)   // nothing external: keep sharing
    }
    @Test func noDisplays() { #expect(Displays.choose([], .automatic) == nil) }
}

@Suite struct IMacModeTests {
    typealias M = Displays.Mode
    @Test func prefers2560x1440HiDPI() {
        let modes = [M(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160),
                     M(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160),
                     M(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880),
                     M(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440)]
        #expect(Displays.bestModeForIMac(modes) == M(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880))
    }
    @Test func largestHiDPIWhen2560Missing() {
        // A 4K dummy usually offers 1920x1080 HiDPI (3840x2160 pixels) but not 2560x1440 HiDPI.
        let modes = [M(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160),
                     M(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160),
                     M(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440),
                     M(width: 1600, height: 1200, pixelWidth: 3200, pixelHeight: 2400)]
        #expect(Displays.bestModeForIMac(modes) == M(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160))
    }
    @Test func non16x9Ignored() {
        #expect(Displays.bestModeForIMac([M(width: 1600, height: 1200, pixelWidth: 3200, pixelHeight: 2400)]) == nil)
    }
    @Test func falls_back_to_lowDPI16x9() {
        let modes = [M(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080),
                     M(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160)]
        #expect(Displays.bestModeForIMac(modes)?.width == 3840)
    }
}
