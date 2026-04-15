import Foundation

/// Codec configuration for SIP media sessions.
public struct SIPCodecConfiguration: Sendable, Equatable {
    /// Codec priority map. Key = codec ID (e.g. "PCMU/8000"), Value = priority (0-255, 0 = disabled).
    public let priorities: [String: UInt8]
    /// Enable Voice Activity Detection.
    public let vadEnabled: Bool

    public init(
        priorities: [String: UInt8] = [:],
        vadEnabled: Bool = false
    ) {
        self.priorities = priorities
        self.vadEnabled = vadEnabled
    }

    public static let `default` = SIPCodecConfiguration()
}
