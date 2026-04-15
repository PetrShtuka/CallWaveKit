import Foundation

/// Delegate protocol for receiving all SDK events.
/// All methods are optional via default empty implementations.
public protocol CallWaveSIPDelegate: AnyObject {
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeRegistrationState state: SIPRegistrationState)
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveIncomingCall call: SIPCall)
    func callWaveSIP(_ sdk: CallWaveSIP, callStateDidChange callID: SIPCall.ID, state: SIPCallState)
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeAudioRoute route: SIPAudioRoute)
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveVoIPPushToken token: Data)
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveVoIPPush payload: [AnyHashable: Any])
    func callWaveSIP(_ sdk: CallWaveSIP, didEncounterError error: SIPError)
}

// Default empty implementations — all methods are optional
public extension CallWaveSIPDelegate {
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeRegistrationState state: SIPRegistrationState) {}
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveIncomingCall call: SIPCall) {}
    func callWaveSIP(_ sdk: CallWaveSIP, callStateDidChange callID: SIPCall.ID, state: SIPCallState) {}
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeAudioRoute route: SIPAudioRoute) {}
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveVoIPPushToken token: Data) {}
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveVoIPPush payload: [AnyHashable: Any]) {}
    func callWaveSIP(_ sdk: CallWaveSIP, didEncounterError error: SIPError) {}
}
