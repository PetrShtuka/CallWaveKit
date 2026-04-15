import Foundation
import Combine

/// Manages SIP account registration lifecycle.
/// Handles create/register/unregister/refresh/remove with state machine tracking.
public final class SIPAccountManager: SIPAccountManagerProtocol {

    private let engine: SIPEngineProtocol
    private let stateSubject: CurrentValueSubject<SIPRegistrationState, Never>
    private var accountId: Int32 = -1 // PJSUA_INVALID_ID
    private var currentConfig: SIPAccountConfiguration?
    private var retryCount: Int = 0
    private let maxRetries = 5
    private var retryWorkItem: DispatchWorkItem?

    public var registrationState: SIPRegistrationState {
        stateSubject.value
    }

    public var registrationStatePublisher: AnyPublisher<SIPRegistrationState, Never> {
        stateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    init(engine: SIPEngineProtocol) {
        self.engine = engine
        self.stateSubject = CurrentValueSubject(.unregistered)
        setupCallbacks()
    }

    deinit {
        retryWorkItem?.cancel()
    }

    // MARK: - Public API

    public func register(with config: SIPAccountConfiguration) throws {
        guard engine.isInitialized else {
            throw SIPError.notInitialized
        }

        // Remove existing account if any
        if accountId >= 0 && engine.isAccountValid(accountId) {
            try? remove()
        }

        currentConfig = config
        retryCount = 0
        transition(.registerRequested)

        sipLog(.info, "Registering account: \(config.username)@\(config.domain):\(config.port)")

        let accId = try engine.createAccount(config: config, autoRegister: true)
        accountId = accId

        sipLog(.info, "Account created with ID: \(accId)")
    }

    public func unregister() throws {
        guard engine.isInitialized, accountId >= 0 else {
            throw SIPError.accountNotRegistered
        }

        transition(.unregisterRequested)
        retryWorkItem?.cancel()

        try engine.setRegistration(active: false, accountId: accountId)
        sipLog(.info, "Unregistration initiated")
    }

    public func refresh() throws {
        guard engine.isInitialized, accountId >= 0 else {
            throw SIPError.accountNotRegistered
        }

        transition(.registerRequested)
        try engine.setRegistration(active: true, accountId: accountId)
        sipLog(.info, "Registration refresh initiated")
    }

    public func remove() throws {
        retryWorkItem?.cancel()
        retryWorkItem = nil

        if accountId >= 0 && engine.isInitialized {
            do {
                try engine.removeAccount(accountId)
                sipLog(.info, "Account \(accountId) removed")
            } catch {
                sipLog(.warning, "Account removal error: \(error)")
            }
        }

        accountId = -1
        currentConfig = nil
        retryCount = 0
        transition(.removeRequested)
    }

    // MARK: - Internal

    private func setupCallbacks() {
        engine.onRegState = { [weak self] accId, statusCode, statusText in
            self?.handleRegistrationState(accId: accId, statusCode: statusCode, statusText: statusText)
        }
    }

    private func handleRegistrationState(accId: Int32, statusCode: Int, statusText: String) {
        guard accId == accountId || accountId < 0 else { return }

        sipLog(.debug, "Registration callback: \(statusCode) \(statusText)")

        if statusCode == 200 {
            // Success
            let expires = engine.getAccountExpiry(accId)
            retryCount = 0
            retryWorkItem?.cancel()
            transition(.registrationSucceeded(expires: expires))
        } else if statusCode == 503 {
            // Network unreachable
            let error = SIPError.networkUnreachable
            transition(.registrationFailed(error))
            scheduleRetry()
        } else if statusCode >= 300 {
            // Other registration errors
            let error = SIPError.registrationFailed(statusCode: statusCode, statusText: statusText)
            transition(.registrationFailed(error))
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        retryCount += 1

        guard retryCount <= maxRetries else {
            sipLog(.warning, "Max registration retries (\(maxRetries)) reached")
            return
        }

        // Exponential backoff: 2, 4, 8, 16, 30 seconds
        let delay = min(Int(pow(2.0, Double(retryCount))), 30)
        sipLog(.info, "Scheduling registration retry \(retryCount)/\(maxRetries) in \(delay)s")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.accountId >= 0, self.engine.isInitialized else { return }
            self.transition(.retryRequested)
            do {
                try self.engine.setRegistration(active: true, accountId: self.accountId)
            } catch {
                sipLog(.error, "Registration retry failed: \(error)")
            }
        }
        retryWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)
    }

    private func transition(_ event: SIPRegistrationState.Event) {
        let current = stateSubject.value
        if let next = current.transition(on: event) {
            stateSubject.send(next)
            sipLog(.debug, "Registration state: \(current) -> \(next)")
        } else {
            sipLog(.debug, "Ignoring invalid registration transition: \(current) + \(event)")
        }
    }
}
