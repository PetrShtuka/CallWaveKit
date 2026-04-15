import XCTest
@testable import CallWaveSIP

final class SIPRegistrationStateTests: XCTestCase {

    // MARK: - From Unregistered

    func testUnregistered_registerRequested_transitionsToRegistering() {
        let state = SIPRegistrationState.unregistered
        let next = state.transition(on: .registerRequested)
        XCTAssertEqual(next, .registering)
    }

    func testUnregistered_unregisterRequested_returnsNil() {
        let state = SIPRegistrationState.unregistered
        XCTAssertNil(state.transition(on: .unregisterRequested))
    }

    // MARK: - From Registering

    func testRegistering_success_transitionsToRegistered() {
        let state = SIPRegistrationState.registering
        let next = state.transition(on: .registrationSucceeded(expires: 600))
        XCTAssertEqual(next, .registered(expires: 600))
    }

    func testRegistering_failure_transitionsToFailed() {
        let state = SIPRegistrationState.registering
        let error = SIPError.networkUnreachable
        let next = state.transition(on: .registrationFailed(error))
        XCTAssertEqual(next, .failed(error))
    }

    // MARK: - From Registered

    func testRegistered_unregisterRequested_transitionsToUnregistering() {
        let state = SIPRegistrationState.registered(expires: 600)
        let next = state.transition(on: .unregisterRequested)
        XCTAssertEqual(next, .unregistering)
    }

    func testRegistered_expired_transitionsToRegistering() {
        let state = SIPRegistrationState.registered(expires: 600)
        let next = state.transition(on: .registrationExpired)
        XCTAssertEqual(next, .registering)
    }

    func testRegistered_failure_transitionsToFailed() {
        let state = SIPRegistrationState.registered(expires: 600)
        let error = SIPError.registrationFailed(statusCode: 503, statusText: "Service Unavailable")
        let next = state.transition(on: .registrationFailed(error))
        XCTAssertEqual(next, .failed(error))
    }

    func testRegistered_registerRequested_refreshes() {
        let state = SIPRegistrationState.registered(expires: 600)
        let next = state.transition(on: .registerRequested)
        XCTAssertEqual(next, .registering)
    }

    // MARK: - From Unregistering

    func testUnregistering_complete_transitionsToUnregistered() {
        let state = SIPRegistrationState.unregistering
        let next = state.transition(on: .unregistrationComplete)
        XCTAssertEqual(next, .unregistered)
    }

    func testUnregistering_failure_transitionsToUnregistered() {
        let state = SIPRegistrationState.unregistering
        let error = SIPError.networkUnreachable
        let next = state.transition(on: .registrationFailed(error))
        XCTAssertEqual(next, .unregistered)
    }

    // MARK: - From Failed

    func testFailed_retryRequested_transitionsToRegistering() {
        let state = SIPRegistrationState.failed(.networkUnreachable)
        let next = state.transition(on: .retryRequested)
        XCTAssertEqual(next, .registering)
    }

    func testFailed_registerRequested_transitionsToRegistering() {
        let state = SIPRegistrationState.failed(.networkUnreachable)
        let next = state.transition(on: .registerRequested)
        XCTAssertEqual(next, .registering)
    }

    func testFailed_removeRequested_transitionsToUnregistered() {
        let state = SIPRegistrationState.failed(.networkUnreachable)
        let next = state.transition(on: .removeRequested)
        XCTAssertEqual(next, .unregistered)
    }

    // MARK: - Invalid Transitions

    func testUnregistered_success_returnsNil() {
        let state = SIPRegistrationState.unregistered
        XCTAssertNil(state.transition(on: .registrationSucceeded(expires: 600)))
    }

    func testRegistering_unregisterRequested_returnsNil() {
        let state = SIPRegistrationState.registering
        XCTAssertNil(state.transition(on: .unregisterRequested))
    }

    // MARK: - Properties

    func testIsRegistered() {
        XCTAssertTrue(SIPRegistrationState.registered(expires: 600).isRegistered)
        XCTAssertFalse(SIPRegistrationState.unregistered.isRegistered)
        XCTAssertFalse(SIPRegistrationState.registering.isRegistered)
        XCTAssertFalse(SIPRegistrationState.failed(.networkUnreachable).isRegistered)
    }
}
