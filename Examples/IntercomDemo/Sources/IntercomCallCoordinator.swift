import AVFoundation
import CallKit
import CallWaveKit
import CallWaveKitAsync
import Foundation
import PushKit

@MainActor
final class IntercomCallCoordinator: NSObject, ObservableObject {
    @Published private(set) var state = "Idle"
    @Published private(set) var caller = "-"
    @Published private(set) var diagnostics = "No snapshot"
    @Published var speakerEnabled = false { didSet { updateSpeaker() } }
    @Published var microphoneMuted = false { didSet { updateMute() } }

    private let provider: CXProvider
    private let callController = CXCallController()
    private let pushRegistry = PKPushRegistry(queue: .main)
    private let client: CallWaveClient
    private var currentUUID: UUID?
    private var eventTask: Task<Void, Never>?

    override init() {
        let providerConfiguration = CXProviderConfiguration(localizedName: "IntercomDemo")
        providerConfiguration.supportsVideo = false
        providerConfiguration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: providerConfiguration)

        let engine = CallWaveEngineConfiguration.defaultConfiguration()
        engine.ipVersionPolicy = .automatic
        engine.statisticsUpdateInterval = 5
        let turnHost = Self.secret("TURNHost")
        if !turnHost.isEmpty {
            engine.turnConfiguration = CallWaveTURNConfiguration(
                server: turnHost,
                transport: .TLS,
                username: Self.secret("TURNUsername"),
                password: Self.secret("TURNPassword")
            )
        }

        client = CallWaveClient(
            configuration: nil,
            options: [],
            provider: provider,
            engineConfiguration: engine
        )
        super.init()

        provider.setDelegate(self, queue: .main)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        client.delegate = self
        try? client.startEngine()
        login()

        eventTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                if let uuid = event.callUUID { currentUUID = uuid }
                if let name = event.caller { caller = name }
                if event.type == .callStateChanged {
                    state = String(describing: event.callState)
                }
                if event.type == .callStatisticsUpdated { refreshDiagnostics() }
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    private func login() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = Self.secret("SIPHost")
            builder.port = UInt(Self.secret("SIPPort")) ?? 5061
            builder.transport = .TLS
            builder.username = Self.secret("SIPUsername")
            builder.password = Self.secret("SIPPassword")
        }
        client.login(configuration: configuration) { _ in }
    }

    func answerCurrentCall() {
        guard let currentUUID else { return }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: currentUUID)))
    }

    func endCurrentCall() {
        guard let currentUUID else { return }
        callController.request(CXTransaction(action: CXEndCallAction(call: currentUUID)))
    }

    func openDoor() {
        client.sendDTMF("#") { _ in }
    }

    func refreshDiagnostics() {
        let snapshot = client.diagnosticsSnapshot().dictionaryRepresentation()
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        diagnostics = String(decoding: data, as: UTF8.self)
    }

    private func updateSpeaker() {
        try? client.setSpeakerEnabled(speakerEnabled)
    }

    private func updateMute() {
        try? client.setMicrophoneMuted(microphoneMuted)
    }

    private static func secret(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

extension IntercomCallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        Task { @MainActor in
            client.acceptCall(uuid: action.callUUID) { error in
                if error != nil {
                    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            client.endCall(uuid: action.callUUID) { _ in action.fulfill() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in client.audioSessionDidActivate(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in client.audioSessionDidDeactivate(audioSession) }
    }
}

extension IntercomCallCoordinator: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // Send pushCredentials.token to your backend over an authenticated API.
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        Task { @MainActor in
            let values = payload.dictionaryPayload
            guard let rawUUID = values["uuid"] as? String,
                  let uuid = UUID(uuidString: rawUUID) else {
                completion()
                return
            }
            if values["cancelled"] as? Bool == true {
                client.handleCancelledIncomingCall(uuid: uuid, reason: .remoteEnded) { _ in
                    provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                    completion()
                }
                return
            }

            let name = values["caller"] as? String ?? "Front door"
            currentUUID = uuid
            caller = name
            client.prepareIncomingCall(uuid: uuid, caller: name)
            let update = CXCallUpdate()
            update.localizedCallerName = name
            update.hasVideo = false
            update.remoteHandle = CXHandle(type: .generic, value: name)
            provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion() }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        // Remove the token from your backend.
    }
}

extension IntercomCallCoordinator: CallWaveClientDelegate {
    nonisolated func callWaveClient(
        _ client: CallWaveClient,
        didEndCallWithUUID uuid: UUID,
        reason: CXCallEndedReason
    ) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    nonisolated func callWaveClientDidInvalidateVoIPPushToken(_ client: CallWaveClient) {
        // Remove the token from your backend if CallWaveKit owns PushKit.
    }
}
