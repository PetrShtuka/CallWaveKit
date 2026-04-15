import Foundation
import Combine
import AVFoundation

/// Main entry point for the CallWaveSIP SDK.
/// Provides a clean, high-level API for SIP/VoIP operations on iOS.
///
/// Usage:
/// ```swift
/// let sip = CallWaveSIP()
/// try sip.initialize(configuration: .default)
/// sip.enableCallKit(configuration: .init(localizedName: "My App"))
/// sip.delegate = self
/// try sip.account.register(with: .init(domain: "sip.example.com", username: "user", password: "pass"))
/// ```
public final class CallWaveSIP: NSObject {

    // MARK: - Public Managers

    /// SIP account registration manager.
    public private(set) var account: SIPAccountManagerProtocol!
    /// SIP call manager.
    public private(set) var calls: SIPCallManagerProtocol!
    /// Audio/media manager.
    public private(set) var media: SIPMediaManagerProtocol!
    /// CallKit adapter (nil until enableCallKit is called).
    public private(set) var callKit: CallKitAdapterProtocol?
    /// VoIP push handler (nil until enableVoIPPush is called).
    public private(set) var voipPush: VoIPPushHandlerProtocol?

    /// Delegate for receiving all SDK events.
    public weak var delegate: CallWaveSIPDelegate?

    /// Whether the SDK is initialized.
    public private(set) var isInitialized = false

    /// Publisher for all SDK events.
    public var eventPublisher: AnyPublisher<SIPEvent, Never> {
        eventSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    // MARK: - Private

    private let engine: SIPEngine
    private let eventSubject = PassthroughSubject<SIPEvent, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var callKitAdapter: CallKitAdapter?
    private var pushHandler: VoIPPushHandler?
    private var callManager: SIPCallManager!
    private var mediaManager: SIPMediaManager!

    /// Creates a new CallWaveSIP instance.
    /// You own the lifecycle — keep a strong reference for the duration of use.
    public override init() {
        engine = SIPEngine()
        super.init()
    }

    // MARK: - Lifecycle

    /// Initialize the SIP engine with the given configuration.
    /// Must be called before any other SDK operations.
    public func initialize(configuration: SIPConfiguration = .default) throws {
        guard !isInitialized else {
            throw SIPError.alreadyInitialized
        }

        // Set log level
        SIPLogger.shared.minimumLevel = configuration.logLevel

        // Initialize PJSIP engine
        try engine.initialize(configuration: configuration)

        // Create managers
        let accountManager = SIPAccountManager(engine: engine)
        callManager = SIPCallManager(engine: engine, accountProvider: { [weak accountManager] in
            // Provide the current account ID via a simple lookup
            guard let mgr = accountManager else { return -1 }
            return mgr.registrationState.isRegistered ? 0 : -1
        })
        mediaManager = SIPMediaManager(engine: engine)

        account = accountManager
        calls = callManager
        media = mediaManager

        // Subscribe to events and forward to delegate + publisher
        bindEvents(accountManager: accountManager)

        isInitialized = true
        sipLog(.info, "CallWaveSIP SDK initialized")
    }

    /// Shutdown the SDK and release all resources.
    public func shutdown() {
        cancellables.removeAll()

        callKitAdapter?.delegate = nil
        callKitAdapter = nil
        callKit = nil

        pushHandler = nil
        voipPush = nil

        try? account?.remove()

        engine.shutdown()
        isInitialized = false

        sipLog(.info, "CallWaveSIP SDK shut down")
    }

    // MARK: - Optional Features

    /// Enable CallKit integration.
    /// Must be called after initialize() but before receiving calls.
    public func enableCallKit(configuration: CallKitConfiguration) {
        let adapter = CallKitAdapter(configuration: configuration)
        adapter.delegate = self
        callKitAdapter = adapter
        callKit = adapter
        sipLog(.info, "CallKit enabled: \(configuration.localizedName)")
    }

    /// Enable VoIP push notification support.
    /// Must be called after enableCallKit().
    public func enableVoIPPush() {
        guard let adapter = callKitAdapter else {
            sipLog(.error, "enableVoIPPush called before enableCallKit")
            return
        }

        let handler = VoIPPushHandler(callKitAdapter: adapter)
        handler.onIncomingPush = { [weak self] uuid, callerName, payload in
            self?.handleVoIPPush(uuid: uuid, callerName: callerName, payload: payload)
        }
        handler.register()

        pushHandler = handler
        voipPush = handler

        // Forward push token to delegate
        handler.tokenPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token in
                guard let self else { return }
                self.delegate?.callWaveSIP(self, didReceiveVoIPPushToken: token)
            }
            .store(in: &cancellables)

        // Forward push payloads to delegate
        handler.pushPayloadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] payload in
                guard let self else { return }
                self.delegate?.callWaveSIP(self, didReceiveVoIPPush: payload)
            }
            .store(in: &cancellables)

        sipLog(.info, "VoIP push enabled")
    }

    // MARK: - Event Binding

    private func bindEvents(accountManager: SIPAccountManager) {
        // Registration state
        accountManager.registrationStatePublisher
            .sink { [weak self] state in
                guard let self else { return }
                self.eventSubject.send(.registrationStateChanged(state))
                self.delegate?.callWaveSIP(self, didChangeRegistrationState: state)
            }
            .store(in: &cancellables)

        // Call state
        callManager.callStatePublisher
            .sink { [weak self] (callID, state) in
                guard let self else { return }
                self.eventSubject.send(.callStateChanged(callID: callID, state: state))
                self.delegate?.callWaveSIP(self, callStateDidChange: callID, state: state)

                // Sync with CallKit
                self.syncCallKitState(callID: callID, state: state)
            }
            .store(in: &cancellables)

        // Incoming calls
        callManager.incomingCallPublisher
            .sink { [weak self] call in
                guard let self else { return }
                self.eventSubject.send(.incomingCall(call))
                self.delegate?.callWaveSIP(self, didReceiveIncomingCall: call)

                // Report to CallKit if enabled and not already reported (VoIP push)
                if let adapter = self.callKitAdapter {
                    adapter.reportIncomingCall(
                        uuid: call.id,
                        callerName: call.remoteDisplayName.isEmpty ? call.remoteURI : call.remoteDisplayName,
                        hasVideo: false
                    ) { _ in }
                }
            }
            .store(in: &cancellables)

        // Audio route
        mediaManager.routePublisher
            .sink { [weak self] route in
                guard let self else { return }
                self.eventSubject.send(.audioRouteChanged(route))
                self.delegate?.callWaveSIP(self, didChangeAudioRoute: route)
            }
            .store(in: &cancellables)
    }

    private func syncCallKitState(callID: SIPCall.ID, state: SIPCallState) {
        guard let adapter = callKitAdapter else { return }

        switch state {
        case .confirmed:
            adapter.reportCallConnected(uuid: callID)
        case .disconnected:
            adapter.reportCallEnded(uuid: callID, reason: .remoteEnded)
        default:
            break
        }
    }

    private func handleVoIPPush(uuid: UUID, callerName: String, payload: [AnyHashable: Any]) {
        // Register a pending incoming call so the CallManager is ready
        // when the SIP INVITE arrives
        callManager?.registerPendingIncomingCall(uuid: uuid, pjCallId: -1)

        // If not initialized yet, the app delegate should handle initialization
        sipLog(.info, "VoIP push handled for UUID: \(uuid)")
    }
}

// MARK: - CallKitAdapterDelegate

extension CallWaveSIP: CallKitAdapterDelegate {

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveAnswerAction uuid: UUID) {
        do {
            try media?.activateAudioDevice()
            try calls?.answer(callID: uuid)
        } catch {
            sipLog(.error, "CallKit answer failed: \(error)")
            delegate?.callWaveSIP(self, didEncounterError: .callAnswerFailed(code: -1))
        }
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveEndAction uuid: UUID) {
        do {
            try calls?.hangup(callID: uuid)
        } catch {
            sipLog(.warning, "CallKit end call: \(error)")
        }
        try? media?.deactivateAudioDevice()
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveStartAction uuid: UUID) {
        // Outgoing call started from CallKit — audio activation
        try? media?.activateAudioDevice()
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveHoldAction uuid: UUID, isOnHold: Bool) {
        do {
            if isOnHold {
                try calls?.hold(callID: uuid)
            } else {
                try calls?.resume(callID: uuid)
            }
        } catch {
            sipLog(.error, "CallKit hold/resume failed: \(error)")
        }
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didReceiveMuteAction uuid: UUID, isMuted: Bool) {
        try? media?.setMuted(isMuted)
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didActivateAudioSession session: AVAudioSession) {
        try? media?.activateAudioDevice()
    }

    public func callKitAdapter(_ adapter: CallKitAdapterProtocol, didDeactivateAudioSession session: AVAudioSession) {
        try? media?.deactivateAudioDevice()
    }

    public func callKitAdapterProviderDidReset(_ adapter: CallKitAdapterProtocol) {
        // Hangup all active calls
        for call in calls?.activeCalls ?? [] {
            try? calls?.hangup(callID: call.id)
        }
        try? media?.deactivateAudioDevice()
        sipLog(.info, "CallKit provider reset — all calls terminated")
    }
}
