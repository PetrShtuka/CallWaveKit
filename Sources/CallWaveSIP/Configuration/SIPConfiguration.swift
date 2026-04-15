import Foundation

/// Master configuration for the SIP SDK engine.
public struct SIPConfiguration: Sendable, Equatable {
    /// Transport settings (UDP/TCP/TLS).
    public let transport: SIPTransportConfiguration
    /// Codec priorities and VAD.
    public let codecs: SIPCodecConfiguration
    /// NAT traversal settings (STUN/TURN/ICE).
    public let nat: SIPNATConfiguration
    /// Minimum log level for SDK logging.
    public let logLevel: SIPLogLevel
    /// Maximum concurrent calls supported.
    public let maxCalls: Int
    /// Custom User-Agent header value.
    public let userAgent: String?
    /// Number of PJSIP worker threads.
    public let threadCount: Int
    /// Enable SIP session timers.
    public let sipTimerActive: Bool
    /// Custom SIP headers to include in all requests.
    public let customHeaders: [String: String]

    public init(
        transport: SIPTransportConfiguration = .default,
        codecs: SIPCodecConfiguration = .default,
        nat: SIPNATConfiguration = .default,
        logLevel: SIPLogLevel = .info,
        maxCalls: Int = 30,
        userAgent: String? = nil,
        threadCount: Int = 1,
        sipTimerActive: Bool = false,
        customHeaders: [String: String] = [:]
    ) {
        self.transport = transport
        self.codecs = codecs
        self.nat = nat
        self.logLevel = logLevel
        self.maxCalls = maxCalls
        self.userAgent = userAgent
        self.threadCount = threadCount
        self.sipTimerActive = sipTimerActive
        self.customHeaders = customHeaders
    }

    public static let `default` = SIPConfiguration()
}
