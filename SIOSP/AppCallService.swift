import AVFoundation
import CallWaveKit

/// Demo-app adapter. It is an ordinary dependency injected by AppDelegate;
/// the library itself has no singleton or knowledge of UserDefaults.
final class AppCallService: NSObject, CallWaveClientDelegate {
    private(set) var client: CallWaveClient?
    private var lastPushPayload: [AnyHashable: Any]?

    private var incomingHandler: (() -> Void)?
    private var connectedHandler: (() -> Void)?
    private var endedHandler: (() -> Void)?

    var currentCallUUID: UUID? { client?.currentCallUUID }
    var currentCaller: String { client?.currentCaller ?? "Intercom" }
    var registered: Bool { client?.isRegistered ?? false }

    @discardableResult
    func configure() -> Bool {
        let defaults = UserDefaults.standard
        let configuration = CallWaveConfiguration(
            domain: defaults.string(forKey: "domain") ?? "",
            username: defaults.string(forKey: "username") ?? "",
            password: defaults.string(forKey: "password") ?? "",
            includesCallsInRecents: false
        )
        return login(with: configuration)
    }

    /// The client outlives individual calls. Credentials that change per push
    /// are applied with `updateConfiguration`, which swaps the SIP account
    /// without recreating the PJSUA stack.
    @discardableResult
    func login(with configuration: CallWaveConfiguration) -> Bool {
        let target = client ?? makeClient()
        do {
            try target.updateConfiguration(configuration)
            client = target
            target.registerForVoIPPushes()
            return true
        } catch {
            print("CallWaveKit login failed: \(error)")
            return false
        }
    }

    private func makeClient() -> CallWaveClient {
        let engine = CallWaveEngineConfiguration.defaultConfiguration()
        engine.userAgent = "SIOSP-Demo"
        #if DEBUG
        engine.logLevel = .info
        #endif

        let client = CallWaveClient(
            configuration: nil,
            options: .managesEverything,
            provider: nil,
            engineConfiguration: engine
        )
        // The library ships a neutral fallback; the product name belongs here.
        client.defaultCallerName = "Intercom"
        client.delegate = self
        return client
    }

    /// Between calls the account is unregistered while the stack stays alive.
    func unregister() {
        do {
            try client?.unregister()
        } catch {
            print("CallWaveKit unregister failed: \(error)")
        }
    }

    func sendDTMF(_ digits: String, completion: ((Error?) -> Void)? = nil) {
        client?.sendDTMF(digits) { error in completion?(error) }
    }

    func stop() {
        client?.stop()
        client = nil
    }

    func refreshRegistration() -> Bool {
        guard let client else { return configure() }
        do {
            try client.refreshRegistration()
            return true
        } catch {
            print("CallWaveKit registration refresh failed: \(error)")
            return false
        }
    }

    func registerForVoIPPushes() {
        client?.registerForVoIPPushes()
    }

    /// `completion` is PushKit's handler. It must reach the library, which only
    /// invokes it once CallKit has accepted the call — acknowledging the push
    /// any earlier is what gets the process killed with `0xBAADCA11`.
    func handleVoIPPush(_ payload: [AnyHashable: Any], completion: (() -> Void)? = nil) {
        lastPushPayload = payload
        if client == nil {
            _ = configure()
        }
        guard let client else {
            completion?()
            return
        }
        client.handleVoIPPushPayload(payload, completion: completion)
    }

    func lastReceivedPushPayload() -> [AnyHashable: Any]? {
        lastPushPayload
    }

    func answer(completion: ((Error?) -> Void)? = nil) {
        client?.answer { error in completion?(error) }
    }

    func decline(completion: ((Error?) -> Void)? = nil) {
        client?.decline { error in completion?(error) }
    }

    func hangup(completion: ((Error?) -> Void)? = nil) {
        client?.hangup { error in completion?(error) }
    }

    func setMuted(_ muted: Bool, completion: ((Error?) -> Void)? = nil) {
        client?.setMuted(muted) { error in completion?(error) }
    }

    @discardableResult
    func setSpeakerEnabled(_ enabled: Bool) -> Bool {
        do {
            try client?.setSpeakerEnabled(enabled)
            return true
        } catch {
            print("CallWaveKit route change failed: \(error)")
            return false
        }
    }

    func configureIncomingCall(_ handler: @escaping () -> Void) {
        incomingHandler = handler
    }

    func configureStartCall(_ handler: @escaping () -> Void) {
        connectedHandler = handler
    }

    func configureEndCall(_ handler: @escaping () -> Void) {
        endedHandler = handler
    }

    func callWaveClient(
        _ client: CallWaveClient,
        didReceiveCallFrom caller: String,
        uuid: UUID
    ) {
        incomingHandler?()
    }

    func callWaveClient(
        _ client: CallWaveClient,
        didChange state: CallWaveCallState,
        uuid: UUID?
    ) {
        switch state {
        case .active:
            connectedHandler?()
        case .ended:
            endedHandler?()
        default:
            break
        }
    }

    func callWaveClient(
        _ client: CallWaveClient,
        didUpdateVoIPPushToken token: String
    ) {
        NotificationCenter.default.post(
            name: .callWaveVoIPTokenUpdated,
            object: self,
            userInfo: ["token": token]
        )
    }

    // MARK: Demo compatibility surface

    func configurePJSIP() -> Int32 { configure() ? 0 : -1 }
    func setupCallKit() {}
    func isRegistered() -> Bool { registered }
    func reRegister() { _ = refreshRegistration() }
    func getCurrentCallUUID() -> UUID? { currentCallUUID }
    func getCurrentCallerInfo() -> String { currentCaller }

    func getCurrentCallStatus() -> Int {
        switch client?.callState {
        case .incoming: return 2
        case .connecting, .active: return 1
        default: return 0
        }
    }

    @discardableResult
    func acceptCall() -> Bool {
        guard currentCallUUID != nil else { return false }
        answer()
        return true
    }

    @discardableResult
    func declineCall() -> Bool {
        guard currentCallUUID != nil else { return false }
        decline()
        return true
    }

    @discardableResult
    func stopCall() -> Bool {
        guard currentCallUUID != nil else { return false }
        hangup()
        return true
    }

    func endCall(with uuid: UUID) { hangup() }
    func connectedCall(with uuid: UUID) {}
    func activateSoundDevice() -> Bool { true }

    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) -> Bool {
        guard currentCallUUID != nil else { return false }
        setMuted(muted)
        return true
    }

    func changeOutputAudioPort(_ port: AVAudioSession.PortOverride) {
        _ = setSpeakerEnabled(port == .speaker)
    }

    func handlePushNotificationPayload(_ payload: [AnyHashable: Any]) {
        handleVoIPPush(payload)
    }

    func handleSwiftPushNotification(_ payload: [AnyHashable: Any]) {
        handleVoIPPush(payload)
    }

    func convertNSDictionaryToSwift(_ dictionary: NSDictionary) -> [AnyHashable: Any] {
        dictionary as? [AnyHashable: Any] ?? [:]
    }
}

extension Notification.Name {
    static let callWaveVoIPTokenUpdated = Notification.Name("CallWaveVoIPTokenUpdated")
}
