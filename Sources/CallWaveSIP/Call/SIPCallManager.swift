import Foundation
import Combine

/// Manages SIP call lifecycle for incoming and outgoing calls.
public final class SIPCallManager: SIPCallManagerProtocol {

    private let engine: SIPEngineProtocol
    private let accountProvider: () -> Int32 // Returns current account ID
    private var calls: [SIPCall.ID: SIPCall] = [:]
    private var pjCallIDMap: [Int32: SIPCall.ID] = [:] // pjsua_call_id -> SIPCall.ID

    private let callStateSubject = PassthroughSubject<(SIPCall.ID, SIPCallState), Never>()
    private let incomingCallSubject = PassthroughSubject<SIPCall, Never>()
    private let lock = NSLock()

    /// Continuation for the case when CallKit answer arrives before SIP INVITE.
    private var pendingAnswerContinuation: ((Int32) -> Void)?

    public var activeCalls: [SIPCall] {
        lock.withLock { Array(calls.values) }
    }

    public var callStatePublisher: AnyPublisher<(SIPCall.ID, SIPCallState), Never> {
        callStateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public var incomingCallPublisher: AnyPublisher<SIPCall, Never> {
        incomingCallSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    init(engine: SIPEngineProtocol, accountProvider: @escaping () -> Int32) {
        self.engine = engine
        self.accountProvider = accountProvider
        setupCallbacks()
    }

    // MARK: - Public API

    public func makeCall(to uri: String) throws -> SIPCall {
        let accountId = accountProvider()
        guard accountId >= 0 else { throw SIPError.accountNotRegistered }

        let pjCallId = try engine.makeCall(uri: uri, accountId: accountId)

        let call = SIPCall(
            direction: .outgoing,
            remoteURI: uri,
            state: .calling,
            pjCallID: pjCallId
        )

        lock.withLock {
            calls[call.id] = call
            pjCallIDMap[pjCallId] = call.id
        }

        callStateSubject.send((call.id, .calling))
        sipLog(.info, "Outgoing call initiated: \(uri)")
        return call
    }

    public func answer(callID: SIPCall.ID) throws {
        guard var call = getCall(callID) else { throw SIPError.callNotFound }

        try engine.answerCallWithSettings(call.pjCallID, code: 200, audioCount: 1, videoCount: 0)

        if let next = call.state.transition(on: .connecting) {
            call.state = next
            updateCall(call)
            callStateSubject.send((callID, next))
        }

        sipLog(.info, "Answered call: \(callID)")
    }

    public func decline(callID: SIPCall.ID, code: SIPStatusCode = .declineCode) throws {
        guard let call = getCall(callID) else { throw SIPError.callNotFound }

        try engine.hangupCall(call.pjCallID, code: code.rawValue)
        sipLog(.info, "Declined call: \(callID) with code \(code.rawValue)")
    }

    public func hangup(callID: SIPCall.ID) throws {
        guard let call = getCall(callID) else { throw SIPError.callNotFound }

        try engine.hangupCall(call.pjCallID, code: 0)
        sipLog(.info, "Hung up call: \(callID)")
    }

    public func hold(callID: SIPCall.ID) throws {
        guard var call = getCall(callID) else { throw SIPError.callNotFound }

        try engine.holdCall(call.pjCallID)

        if let next = call.state.transition(on: .held) {
            call.state = next
            updateCall(call)
            callStateSubject.send((callID, next))
        }

        sipLog(.info, "Call on hold: \(callID)")
    }

    public func resume(callID: SIPCall.ID) throws {
        guard var call = getCall(callID) else { throw SIPError.callNotFound }

        try engine.resumeCall(call.pjCallID)

        if let next = call.state.transition(on: .resumed) {
            call.state = next
            updateCall(call)
            callStateSubject.send((callID, next))
        }

        sipLog(.info, "Call resumed: \(callID)")
    }

    public func sendDTMF(callID: SIPCall.ID, digit: Character) throws {
        guard let call = getCall(callID) else { throw SIPError.callNotFound }
        try engine.sendDTMF(call.pjCallID, digit: String(digit))
        sipLog(.debug, "DTMF sent: \(digit) on call \(callID)")
    }

    public func transfer(callID: SIPCall.ID, to uri: String) throws {
        guard let call = getCall(callID) else { throw SIPError.callNotFound }
        try engine.transferCall(call.pjCallID, to: uri)
        sipLog(.info, "Call transfer initiated: \(callID) -> \(uri)")
    }

    // MARK: - Internal: Used by CallKitAdapter

    /// Find or wait for a call by PJSIP call ID.
    /// This handles the race condition where VoIP push arrives before SIP INVITE.
    func findOrWaitForCall(pjCallId: Int32, timeout: TimeInterval = 10) -> SIPCall.ID? {
        if let id = lock.withLock({ pjCallIDMap[pjCallId] }) {
            return id
        }

        // Wait for the incoming call callback
        var result: SIPCall.ID?
        let semaphore = DispatchSemaphore(value: 0)

        lock.withLock {
            pendingAnswerContinuation = { resolvedCallId in
                if let callUUID = self.lock.withLock({ self.pjCallIDMap[resolvedCallId] }) {
                    result = callUUID
                }
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        lock.withLock { pendingAnswerContinuation = nil }

        if waitResult == .timedOut {
            sipLog(.warning, "Timed out waiting for call with pjCallId: \(pjCallId)")
            return nil
        }

        return result
    }

    /// Register an incoming call from external source (e.g., VoIP push before SIP INVITE).
    func registerPendingIncomingCall(uuid: UUID, pjCallId: Int32 = -1) -> SIPCall {
        let call = SIPCall(
            id: uuid,
            direction: .incoming,
            remoteURI: "",
            state: .incoming,
            pjCallID: pjCallId
        )
        lock.withLock {
            calls[call.id] = call
            if pjCallId >= 0 {
                pjCallIDMap[pjCallId] = call.id
            }
        }
        return call
    }

    // MARK: - Private

    private func setupCallbacks() {
        engine.onIncomingCall = { [weak self] callId, callerUri, callerName in
            self?.handleIncomingCall(callId: callId, callerUri: callerUri, callerName: callerName)
        }

        engine.onCallState = { [weak self] callId, state, statusCode in
            self?.handleCallState(callId: callId, state: state, statusCode: statusCode)
        }
    }

    private func handleIncomingCall(callId: Int32, callerUri: String, callerName: String) {
        // Check if we already have a pending call for this (from VoIP push)
        let existingCallID = lock.withLock { pjCallIDMap[callId] }

        if let existingID = existingCallID {
            // Update existing pending call with the real pj call ID
            lock.withLock {
                if var call = calls[existingID] {
                    call = SIPCall(
                        id: call.id,
                        direction: .incoming,
                        remoteURI: callerUri,
                        remoteDisplayName: callerName,
                        startTime: call.startTime,
                        state: .incoming,
                        pjCallID: callId
                    )
                    calls[existingID] = call
                }
            }
            // Signal pending answer continuation
            lock.withLock { pendingAnswerContinuation?(callId) }
            return
        }

        // Check for active calls — reject if busy
        let currentActiveCount = engine.activeCallCount()
        if currentActiveCount > 1 {
            sipLog(.info, "Rejecting incoming call — busy")
            try? engine.hangupCall(callId, code: 486) // BUSY_HERE
            return
        }

        // Create new incoming call
        let call = SIPCall(
            direction: .incoming,
            remoteURI: callerUri,
            remoteDisplayName: callerName,
            state: .incoming,
            pjCallID: callId
        )

        lock.withLock {
            calls[call.id] = call
            pjCallIDMap[callId] = call.id
        }

        incomingCallSubject.send(call)
        callStateSubject.send((call.id, .incoming))

        // Signal pending answer if waiting
        lock.withLock { pendingAnswerContinuation?(callId) }

        sipLog(.info, "Incoming call from: \(callerName.isEmpty ? callerUri : callerName)")
    }

    private func handleCallState(callId: Int32, state: Int, statusCode: Int) {
        guard let callUUID = lock.withLock({ pjCallIDMap[callId] }),
              var call = getCall(callUUID) else {
            return
        }

        // Map PJSIP inv_state to our event
        let event = mapPJSIPStateToEvent(state: state, statusCode: statusCode)
        guard let event else { return }

        if let next = call.state.transition(on: event) {
            call.state = next
            updateCall(call)
            callStateSubject.send((callUUID, next))

            // Clean up on disconnect
            if case .disconnected = next {
                sipLog(.info, "Call disconnected: \(callUUID)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.removeCall(callUUID, pjCallId: callId)
                }
            }
        }
    }

    private func mapPJSIPStateToEvent(state: Int, statusCode: Int) -> SIPCallState.Event? {
        // PJSIP inv_state values:
        // 1=INCOMING, 2=CALLING, 3=EARLY, 4=CONNECTING, 5=CONFIRMED, 6=DISCONNECTED
        switch state {
        case 1: return .incomingReceived
        case 2: return .outgoingInitiated
        case 3: return .earlyMedia
        case 4: return .connecting
        case 5: return .confirmed
        case 6:
            let reason = mapDisconnectReason(statusCode: statusCode)
            return .disconnected(reason)
        default: return nil
        }
    }

    private func mapDisconnectReason(statusCode: Int) -> SIPDisconnectReason {
        switch statusCode {
        case 200: return .normal
        case 486: return .busy
        case 603: return .declined
        case 408: return .timeout
        case 487: return .remoteCancelled
        case 503: return .networkError
        default:
            if statusCode >= 400 {
                return .error(code: Int32(statusCode))
            }
            return .normal
        }
    }

    private func getCall(_ id: SIPCall.ID) -> SIPCall? {
        lock.withLock { calls[id] }
    }

    private func updateCall(_ call: SIPCall) {
        lock.withLock { calls[call.id] = call }
    }

    private func removeCall(_ id: SIPCall.ID, pjCallId: Int32) {
        lock.withLock {
            calls.removeValue(forKey: id)
            pjCallIDMap.removeValue(forKey: pjCallId)
        }
    }
}
