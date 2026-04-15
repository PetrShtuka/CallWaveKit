import Foundation

/// Log severity levels for the SIP SDK.
public enum SIPLogLevel: Int, Comparable, Sendable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case none = 5

    public static func < (lhs: SIPLogLevel, rhs: SIPLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARNING"
        case .error:   return "ERROR"
        case .none:    return ""
        }
    }
}
