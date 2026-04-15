import Foundation
import Combine

/// Protocol for VoIP push notification handling.
public protocol VoIPPushHandlerProtocol: AnyObject {
    /// Register for VoIP push notifications.
    func register()

    /// Publisher that emits the device push token when received.
    var tokenPublisher: AnyPublisher<Data, Never> { get }

    /// Publisher that emits incoming push payloads.
    var pushPayloadPublisher: AnyPublisher<[AnyHashable: Any], Never> { get }
}
