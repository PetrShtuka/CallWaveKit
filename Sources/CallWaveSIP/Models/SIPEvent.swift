import Foundation

/// Events emitted by the CallWaveSIP SDK via Combine publisher or delegate.
public enum SIPEvent: Sendable {
    case registrationStateChanged(SIPRegistrationState)
    case incomingCall(SIPCall)
    case callStateChanged(callID: SIPCall.ID, state: SIPCallState)
    case audioRouteChanged(SIPAudioRoute)
    case voipPushReceived(payload: [String: String])
    case error(SIPError)
    case transportStateChanged(SIPTransportState)
}
