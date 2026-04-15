import XCTest
import Combine
@testable import CallWaveSIP

final class SIPRegistrationFlowTests: XCTestCase {

    var engine: MockSIPEngine!
    var accountManager: SIPAccountManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        engine = MockSIPEngine()
        engine.isInitialized = true
        accountManager = SIPAccountManager(engine: engine)
        cancellables = []
    }

    func testFullRegistrationCycle() throws {
        var states: [SIPRegistrationState] = []

        accountManager.registrationStatePublisher
            .sink { states.append($0) }
            .store(in: &cancellables)

        // Register
        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            port: 5060,
            username: "testuser",
            password: "testpass"
        )
        try accountManager.register(with: config)

        XCTAssertEqual(engine.createAccountCallCount, 1)
        XCTAssertEqual(accountManager.registrationState, .registering)

        // Simulate successful registration
        engine.simulateRegState(accId: 0, code: 200, text: "OK")

        // Wait for async delivery
        let expectation = XCTestExpectation(description: "State delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(accountManager.registrationState.isRegistered)
    }

    func testRegistrationFailureAndRetry() throws {
        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            username: "testuser",
            password: "testpass"
        )
        try accountManager.register(with: config)

        // Simulate network error
        engine.simulateRegState(accId: 0, code: 503, text: "Service Unavailable")

        let expectation = XCTestExpectation(description: "State delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        if case .failed = accountManager.registrationState {
            // Expected
        } else {
            XCTFail("Expected failed state, got \(accountManager.registrationState)")
        }
    }

    func testRemoveAccount() throws {
        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            username: "testuser",
            password: "testpass"
        )
        try accountManager.register(with: config)
        engine.simulateRegState(accId: 0, code: 200, text: "OK")

        try accountManager.remove()

        XCTAssertEqual(engine.removeAccountCallCount, 1)
        XCTAssertEqual(accountManager.registrationState, .unregistered)
    }

    func testRegisterWithoutInitialization() {
        engine.isInitialized = false

        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            username: "testuser",
            password: "testpass"
        )

        XCTAssertThrowsError(try accountManager.register(with: config)) { error in
            XCTAssertEqual(error as? SIPError, .notInitialized)
        }
    }
}
