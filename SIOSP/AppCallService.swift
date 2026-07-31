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
    var currentCaller: String { client?.currentCaller ?? "Домофон" }
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

        if let client,
           client.configuration.domain == configuration.domain,
           client.configuration.username == configuration.username,
           client.configuration.password == configuration.password {
            if client.isRunning { return true }
        } else {
            client?.stop()
            client = nil
        }

        let newClient = CallWaveClient(configuration: configuration)
        newClient.delegate = self
        do {
            try newClient.start()
            client = newClient
            newClient.registerForVoIPPushes()
            return true
        } catch {
            print("CallWaveKit start failed: \(error)")
            return false
        }
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

    func handleVoIPPush(_ payload: [AnyHashable: Any]) {
        lastPushPayload = payload
        if client == nil {
            _ = configure()
        }
        client?.handleVoIPPushPayload(payload)
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
