#if SWIFT_PACKAGE
import CallWaveKit
#endif

import CallKit
import Foundation

// `CallWaveEvent`, `CallWaveCallStatistics` and `CallWaveConfiguration` are
// declared `NS_SWIFT_SENDABLE` by the Objective-C module itself, so they cross
// isolation boundaries without a retroactive conformance here.

/// Keeps the observer token alive for exactly as long as the stream that owns
/// it, and unregisters once — from whichever task tears the stream down.
private final class EventObservation: @unchecked Sendable {
    private weak var client: CallWaveClient?
    private var token: (any NSCopying & NSObjectProtocol)?
    private let lock = NSLock()

    init(client: CallWaveClient) {
        self.client = client
    }

    func start(_ handler: @escaping (CallWaveEvent) -> Void) {
        let token = client?.addEventObserver(handler)
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token {
            client?.removeEventObserver(token)
        }
    }
}

public extension CallWaveClient {

    /// Dismisses an incoming call that the server cancelled before or while
    /// its INVITE was being matched to the VoIP push.
    func handleCancelledIncomingCall(
        uuid: UUID,
        reason: CXCallEndedReason
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            handleCancelledIncomingCall(uuid: uuid, reason: reason) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Every `CallWaveEvent` the client publishes, as an async sequence.
    ///
    /// The observer is registered when the stream is created and removed when
    /// the consuming task finishes or is cancelled. Each call to this property
    /// makes an independent stream, so several consumers do not steal each
    /// other's events.
    ///
    /// ```swift
    /// for await event in client.events where event.type == .incomingCall {
    ///     await presentIncomingCall(named: event.caller)
    /// }
    /// ```
    var events: AsyncStream<CallWaveEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let observation = EventObservation(client: self)
            observation.start { continuation.yield($0) }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// The events of one call, ending after that call reports `.callEnded`.
    func events(forCallWithUUID uuid: UUID) -> AsyncStream<CallWaveEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let observation = EventObservation(client: self)
            observation.start { event in
                guard event.callUUID == uuid else { return }
                continuation.yield(event)
                if event.type == .callEnded {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// Registration transitions only.
    var registrationStates: AsyncStream<CallWaveRegistrationState> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let observation = EventObservation(client: self)
            observation.start { event in
                guard event.type == .registrationStateChanged else { return }
                continuation.yield(event.registrationState)
            }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// Suspends until the account is registered, or throws
    /// `CallWaveAsyncError.registrationTimedOut` after `timeout` seconds.
    ///
    /// Returns immediately when the account is already registered.
    func waitUntilRegistered(timeout: TimeInterval = 30) async throws {
        if registrationState == .registered {
            return
        }

        // The stream is captured rather than `self`, so the child tasks do not
        // have to reason about the client's isolation.
        let states = registrationStates
        let registered = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states where state == .registered {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }

        if !registered {
            throw CallWaveAsyncError.registrationTimedOut
        }
    }
}

public enum CallWaveAsyncError: Error, Sendable {
    /// `waitUntilRegistered(timeout:)` gave up.
    case registrationTimedOut
}
