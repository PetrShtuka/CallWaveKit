import Foundation
import Combine

/// Protocol for SIP account lifecycle management.
public protocol SIPAccountManagerProtocol: AnyObject {

    /// Register a SIP account with the given configuration.
    func register(with config: SIPAccountConfiguration) throws

    /// Unregister the current SIP account (sends REGISTER with expires=0).
    func unregister() throws

    /// Refresh the current registration.
    func refresh() throws

    /// Remove the account entirely and release resources.
    func remove() throws

    /// Current registration state.
    var registrationState: SIPRegistrationState { get }

    /// Publisher for registration state changes (delivers on main queue).
    var registrationStatePublisher: AnyPublisher<SIPRegistrationState, Never> { get }
}
