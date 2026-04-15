import Foundation
import Combine

/// Protocol abstracting the SIP engine for testability.
/// All operations are thread-safe and dispatched on the engine's serial queue.
public protocol SIPEngineProtocol: AnyObject {

    // MARK: - Lifecycle

    func initialize(configuration: SIPConfiguration) throws
    func shutdown()
    var isInitialized: Bool { get }

    // MARK: - Account

    func createAccount(config: SIPAccountConfiguration, autoRegister: Bool) throws -> Int32
    func removeAccount(_ accountId: Int32) throws
    func setRegistration(active: Bool, accountId: Int32) throws
    func getAccountStatus(_ accountId: Int32) -> Int
    func getAccountExpiry(_ accountId: Int32) -> Int
    func isAccountValid(_ accountId: Int32) -> Bool

    // MARK: - Call

    func makeCall(uri: String, accountId: Int32) throws -> Int32
    func answerCall(_ callId: Int32, code: Int) throws
    func answerCallWithSettings(_ callId: Int32, code: Int, audioCount: Int, videoCount: Int) throws
    func hangupCall(_ callId: Int32, code: Int) throws
    func holdCall(_ callId: Int32) throws
    func resumeCall(_ callId: Int32) throws
    func sendDTMF(_ callId: Int32, digit: String) throws
    func transferCall(_ callId: Int32, to uri: String) throws
    func activeCallCount() -> Int
    func isCallActive(_ callId: Int32) -> Bool
    func getCallState(_ callId: Int32) -> Int
    func getCallMediaStatus(_ callId: Int32) -> Int
    func getCallConfSlot(_ callId: Int32) -> Int
    func getMaxCallCount() -> Int
    func getCallRemoteUri(_ callId: Int32) -> String?
    func getCallRemoteContact(_ callId: Int32) -> String?

    // MARK: - Audio

    func setSoundDevice(capture: Int, playback: Int) throws
    func setNoSoundDevice()
    func connectConferencePort(source: Int, sink: Int) throws
    func disconnectConferencePort(source: Int, sink: Int) throws
    func adjustRxLevel(slot: Int, level: Float) throws
    func adjustTxLevel(slot: Int, level: Float) throws

    // MARK: - Codec

    func setCodecPriority(_ codecId: String, priority: Int) throws
    func getAvailableCodecs() -> [String]

    // MARK: - Callbacks

    var onIncomingCall: ((Int32, String, String) -> Void)? { get set }
    var onCallState: ((Int32, Int, Int) -> Void)? { get set }
    var onCallMediaState: ((Int32, Int) -> Void)? { get set }
    var onRegState: ((Int32, Int, String) -> Void)? { get set }
}
