import Foundation

/// Protocol for custom log handling.
public protocol SIPLoggerProtocol: Sendable {
    func log(_ level: SIPLogLevel, _ message: String, file: String, function: String, line: Int)
}

/// Default logger that writes to os_log / NSLog with configurable minimum level.
public final class SIPLogger: SIPLoggerProtocol, @unchecked Sendable {
    public static let shared = SIPLogger()

    private let lock = NSLock()
    private var _minimumLevel: SIPLogLevel = .info
    private var _customHandler: (@Sendable (SIPLogLevel, String) -> Void)?

    public var minimumLevel: SIPLogLevel {
        get { lock.withLock { _minimumLevel } }
        set { lock.withLock { _minimumLevel = newValue } }
    }

    public var customHandler: (@Sendable (SIPLogLevel, String) -> Void)? {
        get { lock.withLock { _customHandler } }
        set { lock.withLock { _customHandler = newValue } }
    }

    private init() {}

    public func log(
        _ level: SIPLogLevel,
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard level >= minimumLevel else { return }

        let fileName = (file as NSString).lastPathComponent
        let formatted = "[\(level.label)] [\(fileName):\(line)] \(message)"

        if let handler = customHandler {
            handler(level, formatted)
        } else {
            NSLog("[CallWaveSIP] %@", formatted)
        }
    }
}

/// Convenience global logging functions (internal use only).
func sipLog(_ level: SIPLogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    SIPLogger.shared.log(level, message, file: file, function: function, line: line)
}
