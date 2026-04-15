import Foundation

/// Parsed caller information from a SIP URI.
public struct SIPCallInfo: Sendable, Equatable {
    /// Raw SIP URI (e.g. "sip:user@domain").
    public let uri: String
    /// Extracted username/number from the URI.
    public let number: String
    /// Display name if available.
    public let displayName: String

    public init(uri: String, number: String = "", displayName: String = "") {
        self.uri = uri
        self.number = number.isEmpty ? Self.extractNumber(from: uri) : number
        self.displayName = displayName
    }

    /// Extracts the username/number portion from a SIP URI.
    static func extractNumber(from uri: String) -> String {
        // Handle formats: "sip:user@domain", "<sip:user@domain>", "\"Name\" <sip:user@domain>"
        var cleaned = uri

        // Remove display name portion
        if let angleBracketRange = cleaned.range(of: "<") {
            cleaned = String(cleaned[angleBracketRange.lowerBound...])
        }

        // Remove angle brackets
        cleaned = cleaned.replacingOccurrences(of: "<", with: "")
        cleaned = cleaned.replacingOccurrences(of: ">", with: "")

        // Remove sip: or sips: prefix
        cleaned = cleaned.replacingOccurrences(of: "sips:", with: "")
        cleaned = cleaned.replacingOccurrences(of: "sip:", with: "")

        // Take the part before @
        if let atIndex = cleaned.firstIndex(of: "@") {
            return String(cleaned[cleaned.startIndex..<atIndex])
        }

        return cleaned
    }
}
