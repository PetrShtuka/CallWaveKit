import Foundation
import CallKit

/// Protocol for CallKit integration, isolated from SIP/PJSIP internals.
public protocol CallKitAdapterProtocol: AnyObject {

    /// Report an incoming call to the system.
    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool, completion: @escaping (Error?) -> Void)

    /// Report that a call has been connected.
    func reportCallConnected(uuid: UUID)

    /// Report that a call has ended.
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason)

    /// Request the system to start an outgoing call.
    func requestStartCall(uuid: UUID, handle: String, hasVideo: Bool)

    /// Request the system to end a call.
    func requestEndCall(uuid: UUID)
}

/// Delegate for receiving CallKit user actions.
public protocol CallKitAdapterDelegate: AnyObject {
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveAnswerAction uuid: UUID)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveEndAction uuid: UUID)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveStartAction uuid: UUID)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveHoldAction uuid: UUID, isOnHold: Bool)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveMuteAction uuid: UUID, isMuted: Bool)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didActivateAudioSession session: AVAudioSession)
    func callKitAdapter(_ adapter: CallKitAdapterProtocol, didDeactivateAudioSession session: AVAudioSession)
    func callKitAdapterProviderDidReset(_ adapter: CallKitAdapterProtocol)
}
