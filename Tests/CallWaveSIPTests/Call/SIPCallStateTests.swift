import XCTest
@testable import CallWaveSIP

final class SIPCallStateTests: XCTestCase {

    // MARK: - Incoming Call Flow

    func testIdle_incomingReceived_transitionsToIncoming() {
        let state = SIPCallState.idle
        XCTAssertEqual(state.transition(on: .incomingReceived), .incoming)
    }

    func testIncoming_connecting_transitionsToConnecting() {
        let state = SIPCallState.incoming
        XCTAssertEqual(state.transition(on: .connecting), .connecting)
    }

    func testIncoming_confirmed_transitionsToConnecting() {
        let state = SIPCallState.incoming
        XCTAssertEqual(state.transition(on: .confirmed), .connecting)
    }

    func testConnecting_confirmed_transitionsToConfirmed() {
        let state = SIPCallState.connecting
        XCTAssertEqual(state.transition(on: .confirmed), .confirmed)
    }

    // MARK: - Outgoing Call Flow

    func testIdle_outgoingInitiated_transitionsToCalling() {
        let state = SIPCallState.idle
        XCTAssertEqual(state.transition(on: .outgoingInitiated), .calling)
    }

    func testCalling_earlyMedia_transitionsToEarly() {
        let state = SIPCallState.calling
        XCTAssertEqual(state.transition(on: .earlyMedia), .early)
    }

    func testEarly_confirmed_transitionsToConfirmed() {
        let state = SIPCallState.early
        XCTAssertEqual(state.transition(on: .confirmed), .confirmed)
    }

    func testCalling_confirmed_transitionsToConfirmed() {
        let state = SIPCallState.calling
        XCTAssertEqual(state.transition(on: .confirmed), .confirmed)
    }

    // MARK: - Hold / Resume

    func testConfirmed_held_transitionsToOnHold() {
        let state = SIPCallState.confirmed
        XCTAssertEqual(state.transition(on: .held), .onHold)
    }

    func testOnHold_resumed_transitionsToConfirmed() {
        let state = SIPCallState.onHold
        XCTAssertEqual(state.transition(on: .resumed), .confirmed)
    }

    // MARK: - Disconnect

    func testIncoming_disconnected_transitionsToDisconnected() {
        let state = SIPCallState.incoming
        let next = state.transition(on: .disconnected(.remoteCancelled))
        XCTAssertEqual(next, .disconnected(reason: .remoteCancelled))
    }

    func testConfirmed_disconnected_transitionsToDisconnected() {
        let state = SIPCallState.confirmed
        let next = state.transition(on: .disconnected(.normal))
        XCTAssertEqual(next, .disconnected(reason: .normal))
    }

    func testOnHold_disconnected_transitionsToDisconnected() {
        let state = SIPCallState.onHold
        let next = state.transition(on: .disconnected(.busy))
        XCTAssertEqual(next, .disconnected(reason: .busy))
    }

    func testIdle_disconnected_returnsNil() {
        let state = SIPCallState.idle
        XCTAssertNil(state.transition(on: .disconnected(.normal)))
    }

    func testDisconnected_disconnected_returnsNil() {
        let state = SIPCallState.disconnected(reason: .normal)
        XCTAssertNil(state.transition(on: .disconnected(.busy)))
    }

    // MARK: - Invalid Transitions

    func testIdle_confirmed_returnsNil() {
        let state = SIPCallState.idle
        XCTAssertNil(state.transition(on: .confirmed))
    }

    func testConfirmed_incomingReceived_returnsNil() {
        let state = SIPCallState.confirmed
        XCTAssertNil(state.transition(on: .incomingReceived))
    }

    func testOnHold_held_returnsNil() {
        let state = SIPCallState.onHold
        XCTAssertNil(state.transition(on: .held))
    }

    // MARK: - Properties

    func testIsActive() {
        XCTAssertTrue(SIPCallState.confirmed.isActive)
        XCTAssertTrue(SIPCallState.onHold.isActive)
        XCTAssertFalse(SIPCallState.idle.isActive)
        XCTAssertFalse(SIPCallState.incoming.isActive)
        XCTAssertFalse(SIPCallState.disconnected(reason: .normal).isActive)
    }

    func testIsRinging() {
        XCTAssertTrue(SIPCallState.incoming.isRinging)
        XCTAssertTrue(SIPCallState.calling.isRinging)
        XCTAssertTrue(SIPCallState.early.isRinging)
        XCTAssertFalse(SIPCallState.confirmed.isRinging)
        XCTAssertFalse(SIPCallState.idle.isRinging)
    }

    // MARK: - Full Incoming Call Lifecycle

    func testFullIncomingCallLifecycle() {
        var state = SIPCallState.idle

        state = state.transition(on: .incomingReceived)!
        XCTAssertEqual(state, .incoming)

        state = state.transition(on: .connecting)!
        XCTAssertEqual(state, .connecting)

        state = state.transition(on: .confirmed)!
        XCTAssertEqual(state, .confirmed)

        state = state.transition(on: .held)!
        XCTAssertEqual(state, .onHold)

        state = state.transition(on: .resumed)!
        XCTAssertEqual(state, .confirmed)

        state = state.transition(on: .disconnected(.normal))!
        XCTAssertEqual(state, .disconnected(reason: .normal))
    }

    // MARK: - Full Outgoing Call Lifecycle

    func testFullOutgoingCallLifecycle() {
        var state = SIPCallState.idle

        state = state.transition(on: .outgoingInitiated)!
        XCTAssertEqual(state, .calling)

        state = state.transition(on: .earlyMedia)!
        XCTAssertEqual(state, .early)

        state = state.transition(on: .confirmed)!
        XCTAssertEqual(state, .confirmed)

        state = state.transition(on: .disconnected(.normal))!
        XCTAssertEqual(state, .disconnected(reason: .normal))
    }
}
