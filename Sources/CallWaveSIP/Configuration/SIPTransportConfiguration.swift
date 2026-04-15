import Foundation

/// Transport layer configuration for SIP communications.
public struct SIPTransportConfiguration: Sendable, Equatable {
    /// Enable UDP transport (default: true).
    public let udpEnabled: Bool
    /// Enable TCP transport (default: true).
    public let tcpEnabled: Bool
    /// Enable TLS transport (default: false).
    public let tlsEnabled: Bool
    /// Local port for transport binding. 0 = automatic.
    public let port: UInt16
    /// Path to TLS certificate file (required if tlsEnabled).
    public let tlsCertificatePath: String?

    public init(
        udpEnabled: Bool = true,
        tcpEnabled: Bool = true,
        tlsEnabled: Bool = false,
        port: UInt16 = 0,
        tlsCertificatePath: String? = nil
    ) {
        self.udpEnabled = udpEnabled
        self.tcpEnabled = tcpEnabled
        self.tlsEnabled = tlsEnabled
        self.port = port
        self.tlsCertificatePath = tlsCertificatePath
    }

    public static let `default` = SIPTransportConfiguration()
}
