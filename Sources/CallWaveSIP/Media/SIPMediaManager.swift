import Foundation
import Combine

/// Manages audio routing, mute, and sound device activation for SIP calls.
public final class SIPMediaManager: SIPMediaManagerProtocol {

    private let engine: SIPEngineProtocol
    private let configurator = SIPAudioSessionConfigurator()
    private let routeSubject: CurrentValueSubject<SIPAudioRoute, Never>
    private let lock = NSLock()

    private var _isMuted = false
    private var activeCallConfSlot: Int = -1

    // Default audio capture/playback device IDs
    private let defaultCapture: Int = -1  // PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
    private let defaultPlayback: Int = -2 // PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV

    public var isMuted: Bool {
        lock.withLock { _isMuted }
    }

    public var currentRoute: SIPAudioRoute {
        routeSubject.value
    }

    public var routePublisher: AnyPublisher<SIPAudioRoute, Never> {
        routeSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public var availableRoutes: [SIPAudioRoute] {
        configurator.getAvailableRoutes()
    }

    init(engine: SIPEngineProtocol) {
        self.engine = engine
        self.routeSubject = CurrentValueSubject(.builtInReceiver)
        setupMediaCallback()
    }

    // MARK: - Public API

    public func activateAudioDevice() throws {
        try configurator.configureForCall()
        try configurator.activate()

        try engine.setSoundDevice(capture: defaultCapture, playback: defaultPlayback)

        let route = configurator.detectCurrentRoute()
        routeSubject.send(route)

        sipLog(.info, "Audio device activated, route: \(route)")
    }

    public func deactivateAudioDevice() throws {
        engine.setNoSoundDevice()
        configurator.deactivate()

        lock.withLock {
            _isMuted = false
            activeCallConfSlot = -1
        }

        sipLog(.info, "Audio device deactivated")
    }

    public func setAudioRoute(_ route: SIPAudioRoute) throws {
        switch route {
        case .builtInSpeaker:
            try configurator.routeToSpeaker()
        case .builtInReceiver:
            try configurator.routeToReceiver()
        case .bluetooth, .headphones, .headset, .carPlay:
            // For external devices, removing the override lets the system route to them
            try configurator.routeToReceiver()
        }

        routeSubject.send(route)
        sipLog(.info, "Audio route changed to: \(route.displayName)")
    }

    public func setMuted(_ muted: Bool) throws {
        let confSlot = lock.withLock { activeCallConfSlot }
        guard confSlot >= 0 else {
            sipLog(.warning, "Cannot mute — no active call conference slot")
            lock.withLock { _isMuted = muted }
            return
        }

        if muted {
            // Disconnect microphone -> call (TX direction)
            try engine.adjustTxLevel(slot: 0, level: 0.0)
        } else {
            // Reconnect microphone -> call
            try engine.adjustTxLevel(slot: 0, level: 1.0)
        }

        lock.withLock { _isMuted = muted }
        sipLog(.info, "Mute state: \(muted)")
    }

    // MARK: - Internal: Conference Bridge Management

    /// Called when call media becomes active — connects the conference bridge.
    func handleMediaActive(callId: Int32) {
        let confSlot = engine.getCallConfSlot(callId)
        guard confSlot >= 0 else { return }

        lock.withLock { activeCallConfSlot = confSlot }

        // Connect call audio to speaker and microphone to call
        do {
            try engine.connectConferencePort(source: confSlot, sink: 0) // Call -> Speaker
            try engine.connectConferencePort(source: 0, sink: confSlot) // Mic -> Call
            sipLog(.debug, "Conference bridge connected for call slot: \(confSlot)")
        } catch {
            sipLog(.error, "Conference bridge connection failed: \(error)")
        }

        let route = configurator.detectCurrentRoute()
        routeSubject.send(route)
    }

    /// Called when call media becomes inactive.
    func handleMediaInactive(callId: Int32) {
        lock.withLock {
            activeCallConfSlot = -1
            _isMuted = false
        }
    }

    // MARK: - Private

    private func setupMediaCallback() {
        engine.onCallMediaState = { [weak self] callId, mediaStatus in
            // PJSUA_CALL_MEDIA_ACTIVE = 1
            if mediaStatus == 1 {
                self?.handleMediaActive(callId: callId)
            } else {
                self?.handleMediaInactive(callId: callId)
            }
        }
    }
}
