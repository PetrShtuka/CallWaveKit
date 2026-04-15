import Foundation

/// Utilities for bridging between Swift strings and PJSIP/C string types.
enum StringBridge {
    /// Safely converts NSString to a C string pointer for use with PJSIP.
    /// The returned pointer is only valid during the closure execution.
    static func withCString<T>(_ string: String, body: (UnsafePointer<CChar>) -> T) -> T {
        return string.withCString { ptr in
            body(ptr)
        }
    }

    /// Cleans a SIP URI by removing angle brackets and display name portions.
    static func cleanSIPURI(_ uri: String) -> String {
        var cleaned = uri.trimmingCharacters(in: .whitespaces)

        // Remove display name in quotes
        if let quoteEnd = cleaned.range(of: "\"", options: .backwards) {
            let afterQuotes = cleaned[quoteEnd.upperBound...]
            if let angleBracket = afterQuotes.range(of: "<") {
                cleaned = String(afterQuotes[angleBracket.lowerBound...])
            }
        }

        // Remove angle brackets
        cleaned = cleaned.replacingOccurrences(of: "<", with: "")
        cleaned = cleaned.replacingOccurrences(of: ">", with: "")

        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
