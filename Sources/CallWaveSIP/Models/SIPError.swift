import Foundation

/// Typed error hierarchy for all SIP/VoIP operations.
/// Maps PJSIP C error codes and domain-specific failures into Swift-native errors.
public enum SIPError: Error, Equatable, Sendable {

    // MARK: - Initialization

    case pjInitFailed(code: Int32)
    case pjsuaCreateFailed(code: Int32)
    case pjsuaInitFailed(code: Int32)
    case pjsuaStartFailed(code: Int32)

    // MARK: - Transport

    case transportCreationFailed(transport: String, code: Int32)
    case transportNotAvailable

    // MARK: - Account

    case accountCreationFailed(code: Int32)
    case accountInvalid
    case accountNotRegistered
    case registrationFailed(statusCode: Int, statusText: String)

    // MARK: - Call

    case callFailed(code: Int32)
    case callNotFound
    case callInvalidState(current: String, attempted: String)
    case callAnswerFailed(code: Int32)
    case callHangupFailed(code: Int32)
    case dtmfFailed(code: Int32)
    case transferFailed(code: Int32)
    case holdFailed(code: Int32)
    case resumeFailed(code: Int32)
    case maxCallsReached

    // MARK: - Media

    case audioSessionActivationFailed(description: String)
    case audioDeviceSetFailed(code: Int32)
    case conferenceConnectionFailed(code: Int32)

    // MARK: - Network

    case networkUnreachable
    case serverUnreachable(host: String, port: UInt16)
    case timeout

    // MARK: - Thread

    case threadRegistrationFailed(code: Int32)

    // MARK: - CallKit

    case callKitReportFailed(description: String)
    case callKitTransactionFailed(description: String)

    // MARK: - General

    case notInitialized
    case alreadyInitialized
    case invalidConfiguration(reason: String)
    case unknown(code: Int32)
}

extension SIPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pjInitFailed(let code):
            return "PJLIB initialization failed (code: \(code))"
        case .pjsuaCreateFailed(let code):
            return "PJSUA instance creation failed (code: \(code))"
        case .pjsuaInitFailed(let code):
            return "PJSUA initialization failed (code: \(code))"
        case .pjsuaStartFailed(let code):
            return "PJSUA start failed (code: \(code))"
        case .transportCreationFailed(let transport, let code):
            return "\(transport) transport creation failed (code: \(code))"
        case .transportNotAvailable:
            return "No transport available"
        case .accountCreationFailed(let code):
            return "SIP account creation failed (code: \(code))"
        case .accountInvalid:
            return "SIP account is invalid"
        case .accountNotRegistered:
            return "SIP account is not registered"
        case .registrationFailed(let statusCode, let statusText):
            return "SIP registration failed: \(statusCode) \(statusText)"
        case .callFailed(let code):
            return "Call failed (code: \(code))"
        case .callNotFound:
            return "Call not found"
        case .callInvalidState(let current, let attempted):
            return "Invalid call state: cannot perform '\(attempted)' while in '\(current)'"
        case .callAnswerFailed(let code):
            return "Call answer failed (code: \(code))"
        case .callHangupFailed(let code):
            return "Call hangup failed (code: \(code))"
        case .dtmfFailed(let code):
            return "DTMF send failed (code: \(code))"
        case .transferFailed(let code):
            return "Call transfer failed (code: \(code))"
        case .holdFailed(let code):
            return "Call hold failed (code: \(code))"
        case .resumeFailed(let code):
            return "Call resume failed (code: \(code))"
        case .maxCallsReached:
            return "Maximum concurrent calls reached"
        case .audioSessionActivationFailed(let description):
            return "Audio session activation failed: \(description)"
        case .audioDeviceSetFailed(let code):
            return "Audio device configuration failed (code: \(code))"
        case .conferenceConnectionFailed(let code):
            return "Conference bridge connection failed (code: \(code))"
        case .networkUnreachable:
            return "Network is unreachable"
        case .serverUnreachable(let host, let port):
            return "SIP server unreachable: \(host):\(port)"
        case .timeout:
            return "Operation timed out"
        case .threadRegistrationFailed(let code):
            return "PJSIP thread registration failed (code: \(code))"
        case .callKitReportFailed(let description):
            return "CallKit report failed: \(description)"
        case .callKitTransactionFailed(let description):
            return "CallKit transaction failed: \(description)"
        case .notInitialized:
            return "SIP engine is not initialized"
        case .alreadyInitialized:
            return "SIP engine is already initialized"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .unknown(let code):
            return "Unknown SIP error (code: \(code))"
        }
    }
}
