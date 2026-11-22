import Foundation

/// Host session states shown in the menu bar app.
public enum HostState: Equatable {
    case idle
    case starting
    /// Listening on the link, waiting for the iMac.
    case waiting
    case sharing
    case stopping
    case error(String)

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .waiting: return "Waiting for iMac"
        case .sharing: return "Sharing"
        case .stopping: return "Stopping…"
        case let .error(m): return "Error: \(m)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .waiting, .sharing: return true
        default: return false
        }
    }
}

public enum HostEvent: Equatable {
    case start
    case listening
    case clientConnected
    /// `reconnect`: the session keeps waiting for the client instead of stopping.
    case clientLost(reconnect: Bool)
    case stopRequested
    case stopped
    case failed(String)
}

/// Pure transition function: no side effects, unit-tested. Invalid events leave
/// the state unchanged (e.g. a late `clientConnected` after Stop).
public enum HostStateMachine {
    public static func next(_ s: HostState, _ e: HostEvent) -> HostState {
        switch (s, e) {
        case (.idle, .start), (.error, .start): return .starting
        case (.starting, .listening): return .waiting
        case (.waiting, .clientConnected): return .sharing
        case (.sharing, .clientLost(reconnect: true)): return .waiting
        case (.sharing, .clientLost(reconnect: false)): return .stopping
        case (.starting, .stopRequested), (.waiting, .stopRequested), (.sharing, .stopRequested): return .stopping
        case (.stopping, .stopped): return .idle
        case (.starting, .failed(let m)), (.waiting, .failed(let m)), (.sharing, .failed(let m)): return .error(m)
        case (.stopping, .failed(let m)): return .error(m)
        default: return s
        }
    }
}
