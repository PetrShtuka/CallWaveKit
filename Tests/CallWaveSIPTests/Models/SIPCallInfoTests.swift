import XCTest
@testable import CallWaveSIP

final class SIPCallInfoTests: XCTestCase {

    func testExtractNumber_simpleSipUri() {
        let info = SIPCallInfo(uri: "sip:12345@example.com")
        XCTAssertEqual(info.number, "12345")
    }

    func testExtractNumber_withAngleBrackets() {
        let info = SIPCallInfo(uri: "<sip:67890@example.com>")
        XCTAssertEqual(info.number, "67890")
    }

    func testExtractNumber_withDisplayName() {
        let info = SIPCallInfo(uri: "\"John Doe\" <sip:john@example.com>")
        XCTAssertEqual(info.number, "john")
    }

    func testExtractNumber_sipsScheme() {
        let info = SIPCallInfo(uri: "sips:secure@example.com")
        XCTAssertEqual(info.number, "secure")
    }

    func testExtractNumber_noAt() {
        let info = SIPCallInfo(uri: "sip:12345")
        XCTAssertEqual(info.number, "12345")
    }

    func testExplicitNumber_overridesExtraction() {
        let info = SIPCallInfo(uri: "sip:user@example.com", number: "+79991234567")
        XCTAssertEqual(info.number, "+79991234567")
    }
}
