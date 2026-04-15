import Foundation
import Combine

/// Protocol for SIP call lifecycle management.
public protocol SIPCallManagerProtocol: AnyObject {

    /// Make an outgoing call.
    func makeCall(to uri: String) throws -> SIPCall

    /// Answer an incoming call.
    func answer(callID: SIPCall.ID) throws

    /// Decline an incoming call with a SIP status code.
    func decline(callID: SIPCall.ID, code: SIPStatusCode) throws

    /// Hang up an active call.
    func hangup(callID: SIPCall.ID) throws

    /// Put a call on hold.
    func hold(callID: SIPCall.ID) throws

    /// Resume a held call.
    func resume(callID: SIPCall.ID) throws

    /// Send a DTMF tone on an active call.
    func sendDTMF(callID: SIPCall.ID, digit: Character) throws

    /// Transfer a call to another URI.
    func transfer(callID: SIPCall.ID, to uri: String) throws

    /// Currently active calls.
    var activeCalls: [SIPCall] { get }

    /// Publisher for call state changes (delivers on main queue).
    var callStatePublisher: AnyPublisher<(SIPCall.ID, SIPCallState), Never> { get }

    /// Publisher for new incoming calls (delivers on main queue).
    var incomingCallPublisher: AnyPublisher<SIPCall, Never> { get }
}
