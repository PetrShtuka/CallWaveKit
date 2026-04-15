import Foundation

/// State machine for SIP transport connection.
public enum SIPTransportState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(SIPError)

    public enum Event: Equatable, Sendable {
        case connectRequested
        case connected
        case disconnected
        case failed(SIPError)
    }

    public func transition(on event: Event) -> SIPTransportState? {
        switch (self, event) {
        case (.disconnected, .connectRequested):
            return .connecting
        case (.connecting, .connected):
            return .connected
        case (.connecting, .failed(let error)):
            return .failed(error)
        case (.connecting, .disconnected):
            return .disconnected
        case (.connected, .disconnected):
            return .disconnected
        case (.connected, .failed(let error)):
            return .failed(error)
        case (.failed, .connectRequested):
            return .connecting
        case (.failed, .disconnected):
            return .disconnected
        default:
            return nil
        }
    }
}

extension SIPTransportState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed(let error): return "failed: \(error.localizedDescription)"
        }
    }
}
