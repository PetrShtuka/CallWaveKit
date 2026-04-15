import Foundation

/// Available audio routes for SIP calls.
public enum SIPAudioRoute: Equatable, Sendable {
    case builtInSpeaker
    case builtInReceiver
    case bluetooth(name: String)
    case headphones
    case headset
    case carPlay(name: String)

    public var displayName: String {
        switch self {
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "iPhone"
        case .bluetooth(let name): return name
        case .headphones: return "Headphones"
        case .headset: return "Headset"
        case .carPlay(let name): return name
        }
    }

    /// Whether this route uses the speakerphone.
    public var isSpeaker: Bool {
        if case .builtInSpeaker = self { return true }
        return false
    }

    /// Whether this route is a Bluetooth device.
    public var isBluetooth: Bool {
        if case .bluetooth = self { return true }
        return false
    }
}
