import Foundation
import CallWaveSIPObjC

/// Thread-safe Swift wrapper over PJSIPEngine.
/// All PJSIP operations are serialized on a dedicated queue.
final class SIPEngine: SIPEngineProtocol {

    private let engine = PJSIPEngine()
    private let queue = DispatchQueue(label: "com.callwave.sip.engine", qos: .userInitiated)

    // MARK: - Callback Storage

    var onIncomingCall: ((Int32, String, String) -> Void)? {
        didSet { setupCallbacks() }
    }
    var onCallState: ((Int32, Int, Int) -> Void)? {
        didSet { setupCallbacks() }
    }
    var onCallMediaState: ((Int32, Int) -> Void)? {
        didSet { setupCallbacks() }
    }
    var onRegState: ((Int32, Int, String) -> Void)? {
        didSet { setupCallbacks() }
    }

    var isInitialized: Bool {
        engine.isInitialized
    }

    // MARK: - Lifecycle

    func initialize(configuration: SIPConfiguration) throws {
        try dispatchSync { [self] in
            let config = self.buildConfigDict(configuration)
            let result = self.engine.initialize(withConfig: config)
            if result != 0 {
                throw SIPError.pjsuaInitFailed(code: result)
            }
            self.setupCallbacks()
        }
    }

    func shutdown() {
        dispatchSyncVoid {
            self.engine.shutdown()
        }
    }

    // MARK: - Account

    func createAccount(config: SIPAccountConfiguration, autoRegister: Bool) throws -> Int32 {
        try dispatchSync {
            let accId = self.engine.createAccount(
                withDomain: config.domain,
                username: config.username,
                password: config.password,
                port: Int32(config.port),
                realm: config.authRealm,
                regTimeout: Int32(config.registrationTimeout),
                keepAlive: Int32(config.keepAliveInterval),
                retryInterval: Int32(config.retryInterval),
                retryRandomInterval: Int32(config.retryRandomInterval),
                contactRewrite: config.contactRewrite,
                contactUseSourcePort: config.contactUseSourcePort,
                autoRegister: autoRegister
            )
            if accId < 0 {
                throw SIPError.accountCreationFailed(code: Int32(accId))
            }
            return Int32(accId)
        }
    }

    func removeAccount(_ accountId: Int32) throws {
        try dispatchSync {
            let result = self.engine.removeAccount(Int32(accountId))
            if result != 0 {
                throw SIPError.accountInvalid
            }
        }
    }

    func setRegistration(active: Bool, accountId: Int32) throws {
        try dispatchSync {
            let result = self.engine.setRegistration(active, forAccount: Int32(accountId))
            if result != 0 {
                throw SIPError.registrationFailed(statusCode: Int(result), statusText: "setRegistration failed")
            }
        }
    }

    func getAccountStatus(_ accountId: Int32) -> Int {
        dispatchSyncReturn { Int(self.engine.getAccountStatus(Int32(accountId))) }
    }

    func getAccountExpiry(_ accountId: Int32) -> Int {
        dispatchSyncReturn { Int(self.engine.getAccountExpiry(Int32(accountId))) }
    }

    func isAccountValid(_ accountId: Int32) -> Bool {
        dispatchSyncReturn { self.engine.isAccountValid(Int32(accountId)) }
    }

    // MARK: - Call

    func makeCall(uri: String, accountId: Int32) throws -> Int32 {
        try dispatchSync {
            let callId = self.engine.makeCall(uri, account: Int32(accountId))
            if callId < 0 {
                throw SIPError.callFailed(code: Int32(callId))
            }
            return Int32(callId)
        }
    }

    func answerCall(_ callId: Int32, code: Int) throws {
        try dispatchSync {
            let result = self.engine.answerCall(Int32(callId), code: Int32(code))
            if result != 0 {
                throw SIPError.callAnswerFailed(code: result)
            }
        }
    }

    func answerCallWithSettings(_ callId: Int32, code: Int, audioCount: Int, videoCount: Int) throws {
        try dispatchSync {
            let result = self.engine.answerCall(Int32(callId), code: Int32(code),
                                                 audioCount: Int32(audioCount),
                                                 videoCount: Int32(videoCount))
            if result != 0 {
                throw SIPError.callAnswerFailed(code: result)
            }
        }
    }

    func hangupCall(_ callId: Int32, code: Int) throws {
        try dispatchSync {
            let result = self.engine.hangupCall(Int32(callId), code: Int32(code))
            if result != 0 {
                throw SIPError.callHangupFailed(code: result)
            }
        }
    }

    func holdCall(_ callId: Int32) throws {
        try dispatchSync {
            let result = self.engine.holdCall(Int32(callId))
            if result != 0 {
                throw SIPError.holdFailed(code: result)
            }
        }
    }

    func resumeCall(_ callId: Int32) throws {
        try dispatchSync {
            let result = self.engine.resumeCall(Int32(callId))
            if result != 0 {
                throw SIPError.resumeFailed(code: result)
            }
        }
    }

    func sendDTMF(_ callId: Int32, digit: String) throws {
        try dispatchSync {
            let result = self.engine.sendDTMF(Int32(callId), digit: digit)
            if result != 0 {
                throw SIPError.dtmfFailed(code: result)
            }
        }
    }

    func transferCall(_ callId: Int32, to uri: String) throws {
        try dispatchSync {
            let result = self.engine.transferCall(Int32(callId), to: uri)
            if result != 0 {
                throw SIPError.transferFailed(code: result)
            }
        }
    }

    func activeCallCount() -> Int { dispatchSyncReturn { Int(self.engine.activeCallCount()) } }
    func isCallActive(_ callId: Int32) -> Bool { dispatchSyncReturn { self.engine.isCallActive(Int32(callId)) } }
    func getCallState(_ callId: Int32) -> Int { dispatchSyncReturn { Int(self.engine.getCallState(Int32(callId))) } }
    func getCallMediaStatus(_ callId: Int32) -> Int { dispatchSyncReturn { Int(self.engine.getCallMediaStatus(Int32(callId))) } }
    func getCallConfSlot(_ callId: Int32) -> Int { dispatchSyncReturn { Int(self.engine.getCallConfSlot(Int32(callId))) } }
    func getMaxCallCount() -> Int { dispatchSyncReturn { Int(self.engine.getMaxCallCount()) } }
    func getCallRemoteUri(_ callId: Int32) -> String? { dispatchSyncReturn { self.engine.getCallRemoteUri(Int32(callId)) } }
    func getCallRemoteContact(_ callId: Int32) -> String? { dispatchSyncReturn { self.engine.getCallRemoteContact(Int32(callId)) } }

    // MARK: - Audio

    func setSoundDevice(capture: Int, playback: Int) throws {
        try dispatchSync {
            let result = self.engine.setSoundDeviceCapture(Int32(capture), playback: Int32(playback))
            if result != 0 {
                throw SIPError.audioDeviceSetFailed(code: result)
            }
        }
    }

    func setNoSoundDevice() {
        dispatchSyncVoid { self.engine.setNoSoundDevice() }
    }

    func connectConferencePort(source: Int, sink: Int) throws {
        try dispatchSync {
            let result = self.engine.connectConferencePort(Int32(source), to: Int32(sink))
            if result != 0 {
                throw SIPError.conferenceConnectionFailed(code: result)
            }
        }
    }

    func disconnectConferencePort(source: Int, sink: Int) throws {
        try dispatchSync {
            let result = self.engine.disconnectConferencePort(Int32(source), from: Int32(sink))
            if result != 0 {
                throw SIPError.conferenceConnectionFailed(code: result)
            }
        }
    }

    func adjustRxLevel(slot: Int, level: Float) throws {
        try dispatchSync {
            let result = self.engine.adjustRxLevel(Int32(slot), level: level)
            if result != 0 {
                throw SIPError.audioDeviceSetFailed(code: result)
            }
        }
    }

    func adjustTxLevel(slot: Int, level: Float) throws {
        try dispatchSync {
            let result = self.engine.adjustTxLevel(Int32(slot), level: level)
            if result != 0 {
                throw SIPError.audioDeviceSetFailed(code: result)
            }
        }
    }

    // MARK: - Codec

    func setCodecPriority(_ codecId: String, priority: Int) throws {
        try dispatchSync {
            let result = self.engine.setCodecPriority(codecId, priority: Int32(priority))
            if result != 0 {
                throw SIPError.unknown(code: result)
            }
        }
    }

    func getAvailableCodecs() -> [String] {
        dispatchSyncReturn { self.engine.getAvailableCodecs() }
    }

    // MARK: - Private

    private func setupCallbacks() {
        engine.onIncomingCall = { [weak self] callId, uri, name in
            self?.onIncomingCall?(Int32(callId), uri, name)
        }
        engine.onCallState = { [weak self] callId, state, statusCode in
            self?.onCallState?(Int32(callId), Int(state), Int(statusCode))
        }
        engine.onCallMediaState = { [weak self] callId, mediaStatus in
            self?.onCallMediaState?(Int32(callId), Int(mediaStatus))
        }
        engine.onRegState = { [weak self] accId, code, text in
            self?.onRegState?(Int32(accId), Int(code), text)
        }
    }

    private func buildConfigDict(_ config: SIPConfiguration) -> [String: Any] {
        var dict: [String: Any] = [
            "maxCalls": config.maxCalls,
            "threadCount": config.threadCount,
            "vadEnabled": config.codecs.vadEnabled,
            "sipTimerActive": config.sipTimerActive,
            "logLevel": config.logLevel.rawValue,
            "udpEnabled": config.transport.udpEnabled,
            "tcpEnabled": config.transport.tcpEnabled,
            "tlsEnabled": config.transport.tlsEnabled,
            "port": Int(config.transport.port),
            "iceEnabled": config.nat.iceEnabled,
        ]
        if let stun = config.nat.stunServer { dict["stunServer"] = stun }
        if let turn = config.nat.turnServer { dict["turnServer"] = turn }
        if let turnUser = config.nat.turnUsername { dict["turnUsername"] = turnUser }
        if let turnPass = config.nat.turnPassword { dict["turnPassword"] = turnPass }
        if let ua = config.userAgent { dict["userAgent"] = ua }
        if let cert = config.transport.tlsCertificatePath { dict["tlsCertificatePath"] = cert }
        if !config.codecs.priorities.isEmpty {
            dict["codecPriorities"] = config.codecs.priorities.mapValues { Int($0) }
        }
        return dict
    }

    // MARK: - Queue Helpers

    private func dispatchSync<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        queue.sync {
            do {
                result = .success(try work())
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    private func dispatchSyncVoid(_ work: @escaping () -> Void) {
        queue.sync { work() }
    }

    private func dispatchSyncReturn<T>(_ work: @escaping () -> T) -> T {
        queue.sync { work() }
    }
}
