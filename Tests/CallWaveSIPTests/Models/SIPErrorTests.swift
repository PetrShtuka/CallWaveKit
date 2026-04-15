import XCTest
@testable import CallWaveSIP

final class SIPErrorTests: XCTestCase {

    // MARK: - Status Mapper

    func testIsSuccess() {
        XCTAssertTrue(PJSIPStatusMapper.isSuccess(0))
        XCTAssertFalse(PJSIPStatusMapper.isSuccess(1))
        XCTAssertFalse(PJSIPStatusMapper.isSuccess(-1))
    }

    func testMapInitError() {
        let error = PJSIPStatusMapper.mapInitError(70001, operation: .pjInit)
        XCTAssertEqual(error, .pjInitFailed(code: 70001))

        let error2 = PJSIPStatusMapper.mapInitError(70002, operation: .pjsuaCreate)
        XCTAssertEqual(error2, .pjsuaCreateFailed(code: 70002))
    }

    func testMapCallError() {
        let error = PJSIPStatusMapper.mapCallError(1001, operation: .answer)
        XCTAssertEqual(error, .callAnswerFailed(code: 1001))

        let error2 = PJSIPStatusMapper.mapCallError(1002, operation: .dtmf)
        XCTAssertEqual(error2, .dtmfFailed(code: 1002))
    }

    func testMapRegistrationStatus_success() {
        XCTAssertNil(PJSIPStatusMapper.mapRegistrationStatus(200, reason: "OK"))
    }

    func testMapRegistrationStatus_failure() {
        let error = PJSIPStatusMapper.mapRegistrationStatus(503, reason: "Service Unavailable")
        XCTAssertEqual(error, .registrationFailed(statusCode: 503, statusText: "Service Unavailable"))
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions_notNil() {
        let errors: [SIPError] = [
            .pjInitFailed(code: 1),
            .transportCreationFailed(transport: "UDP", code: 2),
            .accountCreationFailed(code: 3),
            .callFailed(code: 4),
            .callNotFound,
            .networkUnreachable,
            .notInitialized,
            .alreadyInitialized,
            .unknown(code: 99),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Empty description for \(error)")
        }
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(SIPError.networkUnreachable, SIPError.networkUnreachable)
        XCTAssertEqual(SIPError.callFailed(code: 42), SIPError.callFailed(code: 42))
        XCTAssertNotEqual(SIPError.callFailed(code: 42), SIPError.callFailed(code: 43))
        XCTAssertNotEqual(SIPError.networkUnreachable, SIPError.timeout)
    }
}
