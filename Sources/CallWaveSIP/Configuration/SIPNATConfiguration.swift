import Foundation

/// NAT traversal configuration (STUN/TURN/ICE).
public struct SIPNATConfiguration: Sendable, Equatable {
    /// STUN server address (e.g. "stun.l.google.com:19302").
    public let stunServer: String?
    /// TURN server address.
    public let turnServer: String?
    /// TURN authentication username.
    public let turnUsername: String?
    /// TURN authentication password.
    public let turnPassword: String?
    /// Enable ICE (Interactive Connectivity Establishment).
    public let iceEnabled: Bool
    /// Enable SIP outbound (RFC 5626).
    public let sipOutboundEnabled: Bool

    public init(
        stunServer: String? = nil,
        turnServer: String? = nil,
        turnUsername: String? = nil,
        turnPassword: String? = nil,
        iceEnabled: Bool = false,
        sipOutboundEnabled: Bool = false
    ) {
        self.stunServer = stunServer
        self.turnServer = turnServer
        self.turnUsername = turnUsername
        self.turnPassword = turnPassword
        self.iceEnabled = iceEnabled
        self.sipOutboundEnabled = sipOutboundEnabled
    }

    public static let `default` = SIPNATConfiguration()
}
