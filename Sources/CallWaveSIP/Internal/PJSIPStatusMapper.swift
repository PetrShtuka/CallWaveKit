import Foundation

/// Maps PJSIP C status codes (pj_status_t / Int32) to typed SIPError values.
enum PJSIPStatusMapper {

    /// Known PJSIP SIP status codes
    static let sipOK: Int32 = 200
    static let sipBadRequest: Int32 = 400
    static let sipUnauthorized: Int32 = 401
    static let sipForbidden: Int32 = 403
    static let sipNotFound: Int32 = 404
    static let sipRequestTimeout: Int32 = 408
    static let sipTemporarilyUnavailable: Int32 = 480
    static let sipBusyHere: Int32 = 486
    static let sipRequestTerminated: Int32 = 487
    static let sipServiceUnavailable: Int32 = 503

    /// PJ_SUCCESS
    static let pjSuccess: Int32 = 0

    /// Maps a raw pj_status_t code from an initialization operation to SIPError.
    static func mapInitError(_ code: Int32, operation: InitOperation) -> SIPError {
        switch operation {
        case .pjInit:
            return .pjInitFailed(code: code)
        case .pjsuaCreate:
            return .pjsuaCreateFailed(code: code)
        case .pjsuaInit:
            return .pjsuaInitFailed(code: code)
        case .pjsuaStart:
            return .pjsuaStartFailed(code: code)
        }
    }

    /// Maps a SIP response status code to a registration error.
    static func mapRegistrationStatus(_ code: Int, reason: String) -> SIPError? {
        if code >= 200 && code < 300 {
            return nil // success
        }
        return .registrationFailed(statusCode: code, statusText: reason)
    }

    /// Maps a raw pj_status_t from a call operation.
    static func mapCallError(_ code: Int32, operation: CallOperation) -> SIPError {
        switch operation {
        case .make:
            return .callFailed(code: code)
        case .answer:
            return .callAnswerFailed(code: code)
        case .hangup:
            return .callHangupFailed(code: code)
        case .hold:
            return .holdFailed(code: code)
        case .resume:
            return .resumeFailed(code: code)
        case .dtmf:
            return .dtmfFailed(code: code)
        case .transfer:
            return .transferFailed(code: code)
        }
    }

    /// Checks if a pj_status_t indicates success.
    static func isSuccess(_ status: Int32) -> Bool {
        return status == pjSuccess
    }

    enum InitOperation {
        case pjInit
        case pjsuaCreate
        case pjsuaInit
        case pjsuaStart
    }

    enum CallOperation {
        case make
        case answer
        case hangup
        case hold
        case resume
        case dtmf
        case transfer
    }
}
