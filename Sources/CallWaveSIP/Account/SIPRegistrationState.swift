import Foundation

/// State machine for SIP account registration lifecycle.
public enum SIPRegistrationState: Equatable, Sendable {
    case unregistered
    case registering
    case registered(expires: Int)
    case unregistering
    case failed(SIPError)

    /// Events that drive registration state transitions.
    public enum Event: Equatable, Sendable {
        case registerRequested
        case registrationSucceeded(expires: Int)
        case registrationFailed(SIPError)
        case unregisterRequested
        case unregistrationComplete
        case registrationExpired
        case retryRequested
        case removeRequested
    }

    /// Computes the next state given an event. Returns nil if the transition is invalid.
    public func transition(on event: Event) -> SIPRegistrationState? {
        switch (self, event) {
        // From unregistered
        case (.unregistered, .registerRequested):
            return .registering

        // From registering
        case (.registering, .registrationSucceeded(let expires)):
            return .registered(expires: expires)
        case (.registering, .registrationFailed(let error)):
            return .failed(error)

        // From registered
        case (.registered, .unregisterRequested):
            return .unregistering
        case (.registered, .registrationExpired):
            return .registering
        case (.registered, .registrationFailed(let error)):
            return .failed(error)
        case (.registered, .registerRequested):
            return .registering // refresh

        // From unregistering
        case (.unregistering, .unregistrationComplete):
            return .unregistered
        case (.unregistering, .registrationFailed):
            return .unregistered // treat unregister failure as unregistered

        // From failed
        case (.failed, .retryRequested):
            return .registering
        case (.failed, .registerRequested):
            return .registering
        case (.failed, .removeRequested):
            return .unregistered

        default:
            return nil
        }
    }
}

extension SIPRegistrationState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unregistered: return "unregistered"
        case .registering: return "registering"
        case .registered(let expires): return "registered (expires: \(expires)s)"
        case .unregistering: return "unregistering"
        case .failed(let error): return "failed: \(error.localizedDescription)"
        }
    }

    /// Whether the account is currently actively registered.
    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}
