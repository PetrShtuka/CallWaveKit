import Foundation
import CallKit
import AVFoundation

/// Isolated CallKit integration layer.
/// Implements CXProviderDelegate and manages CXProvider + CXCallController.
/// Contains NO PJSIP logic — communicates with SIP layer via delegate.
public final class CallKitAdapter: NSObject, CallKitAdapterProtocol, CXProviderDelegate {

    private let provider: CXProvider
    private let callController = CXCallController()
    private let configuration: CallKitConfiguration
    private var reportedUUIDs = Set<UUID>()

    public weak var delegate: CallKitAdapterDelegate?

    public init(configuration: CallKitConfiguration) {
        self.configuration = configuration

        let providerConfig = CXProviderConfiguration()
        providerConfig.localizedName = configuration.localizedName
        providerConfig.supportsVideo = configuration.supportsVideo
        providerConfig.maximumCallsPerCallGroup = configuration.maximumCallsPerCallGroup
        providerConfig.supportedHandleTypes = configuration.supportedHandleTypes
        providerConfig.iconTemplateImageData = configuration.iconTemplateImageData
        if let ringtone = configuration.ringtoneSound {
            providerConfig.ringtoneSound = ringtone
        }

        self.provider = CXProvider(configuration: providerConfig)
        super.init()
        self.provider.setDelegate(self, queue: DispatchQueue.main)
    }

    deinit {
        provider.invalidate()
    }

    // MARK: - CallKitAdapterProtocol

    public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool, completion: @escaping (Error?) -> Void) {
        guard !reportedUUIDs.contains(uuid) else {
            sipLog(.debug, "CallKit: UUID already reported: \(uuid)")
            completion(nil)
            return
        }

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.supportsDTMF = true
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                sipLog(.error, "CallKit: Report incoming call failed: \(error)")
            } else {
                self?.reportedUUIDs.insert(uuid)
                sipLog(.info, "CallKit: Incoming call reported: \(uuid)")
            }
            completion(error)
        }
    }

    public func reportCallConnected(uuid: UUID) {
        provider.reportCall(with: uuid, endedAt: nil, reason: .init(rawValue: 0)!)
        // Use the proper method:
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        sipLog(.info, "CallKit: Call connected: \(uuid)")
    }

    public func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        reportedUUIDs.remove(uuid)
        sipLog(.info, "CallKit: Call ended: \(uuid), reason: \(reason.rawValue)")
    }

    public func requestStartCall(uuid: UUID, handle: String, hasVideo: Bool) {
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        let transaction = CXTransaction(action: action)

        callController.request(transaction) { error in
            if let error {
                sipLog(.error, "CallKit: Start call request failed: \(error)")
            }
        }
    }

    public func requestEndCall(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)

        callController.request(transaction) { error in
            if let error {
                sipLog(.error, "CallKit: End call request failed: \(error)")
            }
        }
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        sipLog(.info, "CallKit: Provider did reset")
        reportedUUIDs.removeAll()
        delegate?.callKitAdapterProviderDidReset(self)
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        sipLog(.info, "CallKit: Answer action for \(action.callUUID)")
        delegate?.callKitAdapter(self, didReceiveAnswerAction: action.callUUID)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        sipLog(.info, "CallKit: End action for \(action.callUUID)")
        delegate?.callKitAdapter(self, didReceiveEndAction: action.callUUID)
        reportedUUIDs.remove(action.callUUID)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        sipLog(.info, "CallKit: Start action for \(action.callUUID)")
        delegate?.callKitAdapter(self, didReceiveStartAction: action.callUUID)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        sipLog(.info, "CallKit: Hold action for \(action.callUUID), onHold: \(action.isOnHold)")
        delegate?.callKitAdapter(self, didReceiveHoldAction: action.callUUID, isOnHold: action.isOnHold)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        sipLog(.info, "CallKit: Mute action for \(action.callUUID), muted: \(action.isMuted)")
        delegate?.callKitAdapter(self, didReceiveMuteAction: action.callUUID, isMuted: action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        sipLog(.info, "CallKit: Audio session activated")
        delegate?.callKitAdapter(self, didActivateAudioSession: audioSession)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        sipLog(.info, "CallKit: Audio session deactivated")
        delegate?.callKitAdapter(self, didDeactivateAudioSession: audioSession)
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        sipLog(.warning, "CallKit: Action timed out: \(type(of: action))")
        action.fulfill()
    }
}
