import Foundation
@testable import CallWaveSIP

/// Mock SIP engine for unit testing without PJSIP dependency.
final class MockSIPEngine: SIPEngineProtocol {

    var isInitialized: Bool = false
    var initializeCallCount = 0
    var shutdownCallCount = 0
    var lastConfig: SIPConfiguration?

    // Account tracking
    var nextAccountId: Int32 = 0
    var accounts: [Int32: Bool] = [:] // accountId -> isRegistered
    var createAccountCallCount = 0
    var removeAccountCallCount = 0
    var setRegistrationCallCount = 0

    // Call tracking
    var nextCallId: Int32 = 100
    var activeCalls_: [Int32: Int] = [:] // callId -> state
    var makeCallCount = 0
    var answerCallCount = 0
    var hangupCallCount = 0
    var holdCallCount = 0
    var resumeCallCount = 0
    var dtmfCallCount = 0
    var transferCallCount = 0

    // Error injection
    var shouldFailInitialize = false
    var shouldFailCreateAccount = false
    var shouldFailAnswerCall = false
    var shouldFailHangup = false

    // Callbacks
    var onIncomingCall: ((Int32, String, String) -> Void)?
    var onCallState: ((Int32, Int, Int) -> Void)?
    var onCallMediaState: ((Int32, Int) -> Void)?
    var onRegState: ((Int32, Int, String) -> Void)?

    // MARK: - Lifecycle

    func initialize(configuration: SIPConfiguration) throws {
        initializeCallCount += 1
        lastConfig = configuration
        if shouldFailInitialize {
            throw SIPError.pjsuaInitFailed(code: -1)
        }
        isInitialized = true
    }

    func shutdown() {
        shutdownCallCount += 1
        isInitialized = false
    }

    // MARK: - Account

    func createAccount(config: SIPAccountConfiguration, autoRegister: Bool) throws -> Int32 {
        createAccountCallCount += 1
        if shouldFailCreateAccount {
            throw SIPError.accountCreationFailed(code: -1)
        }
        let id = nextAccountId
        nextAccountId += 1
        accounts[id] = autoRegister
        return id
    }

    func removeAccount(_ accountId: Int32) throws {
        removeAccountCallCount += 1
        accounts.removeValue(forKey: accountId)
    }

    func setRegistration(active: Bool, accountId: Int32) throws {
        setRegistrationCallCount += 1
        accounts[accountId] = active
    }

    func getAccountStatus(_ accountId: Int32) -> Int {
        accounts[accountId] == true ? 200 : 0
    }

    func getAccountExpiry(_ accountId: Int32) -> Int { 600 }
    func isAccountValid(_ accountId: Int32) -> Bool { accounts[accountId] != nil }

    // MARK: - Call

    func makeCall(uri: String, accountId: Int32) throws -> Int32 {
        makeCallCount += 1
        let id = nextCallId
        nextCallId += 1
        activeCalls_[id] = 2 // CALLING
        return id
    }

    func answerCall(_ callId: Int32, code: Int) throws {
        answerCallCount += 1
        if shouldFailAnswerCall { throw SIPError.callAnswerFailed(code: -1) }
        activeCalls_[callId] = 5 // CONFIRMED
    }

    func answerCallWithSettings(_ callId: Int32, code: Int, audioCount: Int, videoCount: Int) throws {
        try answerCall(callId, code: code)
    }

    func hangupCall(_ callId: Int32, code: Int) throws {
        hangupCallCount += 1
        if shouldFailHangup { throw SIPError.callHangupFailed(code: -1) }
        activeCalls_.removeValue(forKey: callId)
    }

    func holdCall(_ callId: Int32) throws { holdCallCount += 1 }
    func resumeCall(_ callId: Int32) throws { resumeCallCount += 1 }
    func sendDTMF(_ callId: Int32, digit: String) throws { dtmfCallCount += 1 }
    func transferCall(_ callId: Int32, to uri: String) throws { transferCallCount += 1 }

    func activeCallCount() -> Int { activeCalls_.count }
    func isCallActive(_ callId: Int32) -> Bool { activeCalls_[callId] != nil }
    func getCallState(_ callId: Int32) -> Int { activeCalls_[callId] ?? -1 }
    func getCallMediaStatus(_ callId: Int32) -> Int { activeCalls_[callId] == 5 ? 1 : 0 }
    func getCallConfSlot(_ callId: Int32) -> Int { activeCalls_[callId] != nil ? 1 : -1 }
    func getMaxCallCount() -> Int { 30 }
    func getCallRemoteUri(_ callId: Int32) -> String? { "sip:test@example.com" }
    func getCallRemoteContact(_ callId: Int32) -> String? { "Test User" }

    // MARK: - Audio

    func setSoundDevice(capture: Int, playback: Int) throws {}
    func setNoSoundDevice() {}
    func connectConferencePort(source: Int, sink: Int) throws {}
    func disconnectConferencePort(source: Int, sink: Int) throws {}
    func adjustRxLevel(slot: Int, level: Float) throws {}
    func adjustTxLevel(slot: Int, level: Float) throws {}

    // MARK: - Codec

    func setCodecPriority(_ codecId: String, priority: Int) throws {}
    func getAvailableCodecs() -> [String] { ["PCMU/8000", "PCMA/8000", "opus/48000"] }

    // MARK: - Simulation Helpers

    func simulateIncomingCall(callId: Int32, uri: String, name: String) {
        activeCalls_[callId] = 1 // INCOMING
        onIncomingCall?(callId, uri, name)
    }

    func simulateCallState(callId: Int32, state: Int, statusCode: Int) {
        if state == 6 { // DISCONNECTED
            activeCalls_.removeValue(forKey: callId)
        } else {
            activeCalls_[callId] = state
        }
        onCallState?(callId, state, statusCode)
    }

    func simulateRegState(accId: Int32, code: Int, text: String) {
        if code == 200 {
            accounts[accId] = true
        }
        onRegState?(accId, code, text)
    }
}
