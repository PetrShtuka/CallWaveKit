import Foundation

/// Actions that can be performed on a SIP call.
public enum SIPCallAction: Sendable {
    case answer
    case decline(code: SIPStatusCode)
    case hangup
    case hold
    case resume
    case sendDTMF(digit: Character)
    case transfer(uri: String)
    case addToConference
}

/// Common SIP response status codes.
public enum SIPStatusCode: Int, Sendable {
    case ok = 200
    case ringing = 180
    case sessionProgress = 183
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case requestTimeout = 408
    case temporarilyUnavailable = 480
    case busyHere = 486
    case requestTerminated = 487
    case serviceUnavailable = 503
    case declineCode = 603
}
