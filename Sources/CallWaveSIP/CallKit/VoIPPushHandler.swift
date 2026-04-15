import Foundation
import PushKit
import Combine

/// Handles VoIP push notification registration and processing.
/// Implements PKPushRegistryDelegate. Reports incoming calls to CallKitAdapter.
public final class VoIPPushHandler: NSObject, VoIPPushHandlerProtocol, PKPushRegistryDelegate {

    private var pushRegistry: PKPushRegistry?
    private let callKitAdapter: CallKitAdapterProtocol
    private let tokenSubject = PassthroughSubject<Data, Never>()
    private let pushPayloadSubject = PassthroughSubject<[AnyHashable: Any], Never>()

    /// Called when a VoIP push is received and needs to create an incoming call.
    /// Parameters: UUID for the call, caller name, payload dictionary.
    public var onIncomingPush: ((UUID, String, [AnyHashable: Any]) -> Void)?

    public var tokenPublisher: AnyPublisher<Data, Never> {
        tokenSubject.eraseToAnyPublisher()
    }

    public var pushPayloadPublisher: AnyPublisher<[AnyHashable: Any], Never> {
        pushPayloadSubject.eraseToAnyPublisher()
    }

    init(callKitAdapter: CallKitAdapterProtocol) {
        self.callKitAdapter = callKitAdapter
        super.init()
    }

    // MARK: - VoIPPushHandlerProtocol

    public func register() {
        let registry = PKPushRegistry(queue: DispatchQueue.main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
        sipLog(.info, "VoIP push registration initiated")
    }

    // MARK: - PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        sipLog(.info, "VoIP push token received: \(tokenString)")
        tokenSubject.send(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let payloadDict = payload.dictionaryPayload

        sipLog(.info, "VoIP push received")
        pushPayloadSubject.send(payloadDict)

        // Extract caller info from payload
        let callerName = extractCallerName(from: payloadDict)
        let callUUID = UUID()

        // MUST report to CallKit synchronously before calling completion
        callKitAdapter.reportIncomingCall(uuid: callUUID, callerName: callerName, hasVideo: false) { error in
            if let error {
                sipLog(.error, "VoIP push: Failed to report incoming call: \(error)")
            }
            completion()
        }

        // Notify SDK to initialize SIP and prepare for the call
        onIncomingPush?(callUUID, callerName, payloadDict)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        sipLog(.info, "VoIP push token invalidated")
    }

    // MARK: - Private

    private func extractCallerName(from payload: [AnyHashable: Any]) -> String {
        // Try common payload keys
        if let callerId = payload["caller_id"] as? String, !callerId.isEmpty {
            return callerId
        }
        if let aps = payload["aps"] as? [String: Any],
           let alert = aps["alert"] as? String, !alert.isEmpty {
            return alert
        }
        if let caller = payload["caller"] as? String, !caller.isEmpty {
            return caller
        }
        return "Incoming Call"
    }
}
