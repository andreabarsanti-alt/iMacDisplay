import Testing
@testable import HostCore

@Suite struct HostStateMachineTests {
    typealias M = HostStateMachine

    @Test func happyPath() {
        var s = HostState.idle
        for e in [HostEvent.start, .listening, .clientConnected, .stopRequested, .stopped] { s = M.next(s, e) }
        #expect(s == .idle)
    }

    @Test func eachStep() {
        #expect(M.next(.idle, .start) == .starting)
        #expect(M.next(.starting, .listening) == .waiting)
        #expect(M.next(.waiting, .clientConnected) == .sharing)
        #expect(M.next(.sharing, .stopRequested) == .stopping)
        #expect(M.next(.stopping, .stopped) == .idle)
    }

    @Test func reconnectKeepsWaiting() {
        #expect(M.next(.sharing, .clientLost(reconnect: true)) == .waiting)
        #expect(M.next(.sharing, .clientLost(reconnect: false)) == .stopping)
    }

    @Test func failuresEndInError() {
        #expect(M.next(.starting, .failed("Screen Recording not granted")) == .error("Screen Recording not granted"))
        #expect(M.next(.sharing, .failed("cable")) == .error("cable"))
        #expect(M.next(.stopping, .failed("x")) == .error("x"))
    }

    @Test func canRestartAfterError() {
        #expect(M.next(.error("x"), .start) == .starting)
    }

    @Test func stopFromAnyActiveState() {
        for s in [HostState.starting, .waiting, .sharing] { #expect(M.next(s, .stopRequested) == .stopping) }
    }

    @Test func lateEventsAreIgnored() {
        // e.g. a client connecting after Stop, or a second Start while sharing
        #expect(M.next(.idle, .clientConnected) == .idle)
        #expect(M.next(.stopping, .clientConnected) == .stopping)
        #expect(M.next(.sharing, .start) == .sharing)
        #expect(M.next(.idle, .stopRequested) == .idle)
        #expect(M.next(.idle, .stopped) == .idle)
    }

    @Test func activeFlag() {
        #expect(HostState.sharing.isActive && HostState.waiting.isActive && HostState.starting.isActive)
        #expect(!HostState.idle.isActive && !HostState.stopping.isActive && !HostState.error("x").isActive)
    }
}

@Suite struct LinkCheckTests {
    @Test func loopbackIsUp() { #expect(LinkCheck.localAddressProblem("127.0.0.1") == nil) }
    @Test func missingAddressIsReported() {
        #expect(LinkCheck.localAddressProblem("10.255.255.254")?.contains("no interface") == true)
    }
}
