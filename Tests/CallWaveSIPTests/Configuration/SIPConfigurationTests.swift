import XCTest
@testable import CallWaveSIP

final class SIPConfigurationTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = SIPConfiguration.default
        XCTAssertTrue(config.transport.udpEnabled)
        XCTAssertTrue(config.transport.tcpEnabled)
        XCTAssertFalse(config.transport.tlsEnabled)
        XCTAssertEqual(config.transport.port, 0)
        XCTAssertEqual(config.maxCalls, 30)
        XCTAssertEqual(config.threadCount, 1)
        XCTAssertFalse(config.codecs.vadEnabled)
        XCTAssertFalse(config.sipTimerActive)
        XCTAssertNil(config.userAgent)
        XCTAssertTrue(config.customHeaders.isEmpty)
    }

    func testCustomConfiguration() {
        let config = SIPConfiguration(
            transport: .init(udpEnabled: true, tcpEnabled: false, tlsEnabled: true, port: 5060),
            codecs: .init(priorities: ["PCMU/8000": 255], vadEnabled: true),
            nat: .init(stunServer: "stun.example.com", iceEnabled: true),
            logLevel: .debug,
            maxCalls: 10,
            userAgent: "TestApp/1.0"
        )

        XCTAssertFalse(config.transport.tcpEnabled)
        XCTAssertTrue(config.transport.tlsEnabled)
        XCTAssertEqual(config.transport.port, 5060)
        XCTAssertEqual(config.codecs.priorities["PCMU/8000"], 255)
        XCTAssertTrue(config.codecs.vadEnabled)
        XCTAssertEqual(config.nat.stunServer, "stun.example.com")
        XCTAssertTrue(config.nat.iceEnabled)
        XCTAssertEqual(config.maxCalls, 10)
        XCTAssertEqual(config.userAgent, "TestApp/1.0")
    }

    func testAccountConfiguration() {
        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            port: 5567,
            username: "testuser",
            password: "testpass"
        )

        XCTAssertEqual(config.domain, "sip.example.com")
        XCTAssertEqual(config.port, 5567)
        XCTAssertEqual(config.username, "testuser")
        XCTAssertEqual(config.authRealm, "*")
        XCTAssertEqual(config.registrationTimeout, 600)
        XCTAssertEqual(config.keepAliveInterval, 15)
        XCTAssertTrue(config.contactRewrite)
        XCTAssertEqual(config.sipURI, "sip:testuser@sip.example.com:5567")
        XCTAssertEqual(config.registrarURI, "sip:sip.example.com:5567")
    }

    func testAccountConfiguration_defaultPort() {
        let config = SIPAccountConfiguration(
            domain: "sip.example.com",
            username: "user",
            password: "pass"
        )
        // Default port 5060 should not appear in URI
        XCTAssertEqual(config.sipURI, "sip:user@sip.example.com")
        XCTAssertEqual(config.registrarURI, "sip:sip.example.com")
    }

    func testTransportState() {
        var state = SIPTransportState.disconnected

        let next = state.transition(on: .connectRequested)
        XCTAssertEqual(next, .connecting)
        state = next!

        let connected = state.transition(on: .connected)
        XCTAssertEqual(connected, .connected)
        state = connected!

        let disconnected = state.transition(on: .disconnected)
        XCTAssertEqual(disconnected, .disconnected)
    }
}
