import Foundation

/// Reason for call disconnection.
public enum SIPDisconnectReason: Equatable, Sendable {
    case normal
    case busy
    case declined
    case timeout
    case error(code: Int32)
    case networkError
    case remoteCancelled
}

/// State machine for SIP call lifecycle.
public enum SIPCallState: Equatable, Sendable {
    case idle
    case incoming
    case calling
    case early
    case connecting
    case confirmed
    case onHold
    case disconnected(reason: SIPDisconnectReason)

    /// Events that drive call state transitions.
    public enum Event: Equatable, Sendable {
        case incomingReceived
        case outgoingInitiated
        case earlyMedia
        case connecting
        case confirmed
        case held
        case resumed
        case disconnected(SIPDisconnectReason)
    }

    /// Computes the next state given an event. Returns nil if the transition is invalid.
    public func transition(on event: Event) -> SIPCallState? {
        // Disconnect is always valid from any non-idle, non-disconnected state
        if case .disconnected(let reason) = event {
            switch self {
            case .idle, .disconnected:
                return nil
            default:
                return .disconnected(reason: reason)
            }
        }

        switch (self, event) {
        // From idle
        case (.idle, .incomingReceived):
            return .incoming
        case (.idle, .outgoingInitiated):
            return .calling

        // From incoming
        case (.incoming, .confirmed):
            return .connecting
        case (.incoming, .connecting):
            return .connecting

        // From calling
        case (.calling, .earlyMedia):
            return .early
        case (.calling, .connecting):
            return .connecting
        case (.calling, .confirmed):
            return .confirmed

        // From early
        case (.early, .connecting):
            return .connecting
        case (.early, .confirmed):
            return .confirmed

        // From connecting
        case (.connecting, .confirmed):
            return .confirmed

        // From confirmed
        case (.confirmed, .held):
            return .onHold

        // From onHold
        case (.onHold, .resumed):
            return .confirmed

        default:
            return nil
        }
    }
}

extension SIPCallState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .incoming: return "incoming"
        case .calling: return "calling"
        case .early: return "early"
        case .connecting: return "connecting"
        case .confirmed: return "confirmed"
        case .onHold: return "on hold"
        case .disconnected(let reason): return "disconnected (\(reason))"
        }
    }

    /// Whether the call is currently active (connected or on hold).
    public var isActive: Bool {
        switch self {
        case .confirmed, .onHold: return true
        default: return false
        }
    }

    /// Whether the call is in a ringing/pending state.
    public var isRinging: Bool {
        switch self {
        case .incoming, .calling, .early: return true
        default: return false
        }
    }
}
