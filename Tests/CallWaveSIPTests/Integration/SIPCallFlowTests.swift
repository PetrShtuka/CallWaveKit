import XCTest
import Combine
@testable import CallWaveSIP

final class SIPCallFlowTests: XCTestCase {

    var engine: MockSIPEngine!
    var callManager: SIPCallManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        engine = MockSIPEngine()
        engine.isInitialized = true
        callManager = SIPCallManager(engine: engine, accountProvider: { 0 })
        cancellables = []
    }

    func testIncomingCallFlow_answerAndHangup() throws {
        var receivedStates: [(SIPCall.ID, SIPCallState)] = []

        callManager.callStatePublisher
            .sink { receivedStates.append($0) }
            .store(in: &cancellables)

        // Simulate incoming call
        engine.simulateIncomingCall(callId: 10, uri: "sip:caller@example.com", name: "Caller")

        let expectation1 = XCTestExpectation(description: "Incoming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation1.fulfill() }
        wait(for: [expectation1], timeout: 1.0)

        XCTAssertEqual(callManager.activeCalls.count, 1)
        let call = callManager.activeCalls.first!
        XCTAssertEqual(call.direction, .incoming)

        // Answer
        try callManager.answer(callID: call.id)
        XCTAssertEqual(engine.answerCallCount, 1)

        // Simulate confirmed state
        engine.simulateCallState(callId: 10, state: 5, statusCode: 200)

        let expectation2 = XCTestExpectation(description: "Confirmed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation2.fulfill() }
        wait(for: [expectation2], timeout: 1.0)

        // Hangup
        try callManager.hangup(callID: call.id)
        XCTAssertEqual(engine.hangupCallCount, 1)
    }

    func testIncomingCallFlow_decline() throws {
        engine.simulateIncomingCall(callId: 11, uri: "sip:caller@example.com", name: "Caller")

        let expectation = XCTestExpectation(description: "Incoming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let call = callManager.activeCalls.first!
        try callManager.decline(callID: call.id, code: .busyHere)
        XCTAssertEqual(engine.hangupCallCount, 1)
    }

    func testDTMF() throws {
        engine.simulateIncomingCall(callId: 12, uri: "sip:caller@example.com", name: "")

        let expectation = XCTestExpectation(description: "Incoming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let call = callManager.activeCalls.first!
        try callManager.answer(callID: call.id)
        try callManager.sendDTMF(callID: call.id, digit: "5")
        XCTAssertEqual(engine.dtmfCallCount, 1)
    }

    func testHangupNonexistentCall() {
        XCTAssertThrowsError(try callManager.hangup(callID: UUID())) { error in
            XCTAssertEqual(error as? SIPError, .callNotFound)
        }
    }

    func testCallDisconnectCleansUp() throws {
        engine.simulateIncomingCall(callId: 13, uri: "sip:caller@example.com", name: "")

        let expectation = XCTestExpectation(description: "Incoming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(callManager.activeCalls.count, 1)

        // Simulate disconnect
        engine.simulateCallState(callId: 13, state: 6, statusCode: 200)

        // Wait for cleanup (0.5s delay + main queue delivery)
        let expectation2 = XCTestExpectation(description: "Cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { expectation2.fulfill() }
        wait(for: [expectation2], timeout: 2.0)

        XCTAssertEqual(callManager.activeCalls.count, 0)
    }
}
