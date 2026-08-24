import XCTest

@testable import CallWaveKit

final class CallWaveConfigurationTests: XCTestCase {

    // MARK: - URI construction

    func testIdentityURICarriesNeitherPortNorTransport() {
        let configuration = CallWaveConfiguration(
            host: "sip.example.com",
            port: 5070,
            transport: .TCP,
            username: "1001",
            password: "secret",
            includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.identityURI, "sip:1001@sip.example.com")
    }

    func testRegistrarURIUsesExplicitPortAndTransportParameter() {
        let configuration = CallWaveConfiguration(
            host: "sip.example.com",
            port: 5070,
            transport: .TCP,
            username: "1001",
            password: "secret",
            includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.registrarURI, "sip:sip.example.com:5070;transport=tcp")
    }

    func testRegistrarURIFallsBackToTransportDefaultPort() {
        let udp = CallWaveConfiguration(
            host: "10.0.0.5", port: 0, transport: .UDP,
            username: "a", password: "b", includesCallsInRecents: false
        )
        let tls = CallWaveConfiguration(
            host: "10.0.0.5", port: 0, transport: .TLS,
            username: "a", password: "b", includesCallsInRecents: false
        )

        XCTAssertEqual(udp.registrarURI, "sip:10.0.0.5:5060")
        XCTAssertEqual(tls.registrarURI, "sip:10.0.0.5:5061;transport=tls")
    }

    // MARK: - Domain parsing

    func testDomainInitializerSplitsTrailingPort() {
        let configuration = CallWaveConfiguration(
            domain: "sip.example.com:5080",
            username: "1001",
            password: "secret",
            includesCallsInRecents: true
        )

        XCTAssertEqual(configuration.host, "sip.example.com")
        XCTAssertEqual(configuration.port, 5080)
        XCTAssertEqual(configuration.domain, "sip.example.com:5080")
    }

    func testDomainInitializerKeepsHostWhenThereIsNoPort() {
        let configuration = CallWaveConfiguration(
            domain: "sip.example.com",
            username: "1001", password: "secret", includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.host, "sip.example.com")
        XCTAssertEqual(configuration.port, 0)
        XCTAssertEqual(configuration.domain, "sip.example.com")
    }

    func testDomainInitializerLeavesBracketedIPv6Intact() {
        let configuration = CallWaveConfiguration(
            domain: "[2001:db8::1]",
            username: "1001", password: "secret", includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.host, "[2001:db8::1]")
        XCTAssertEqual(configuration.port, 0)
    }

    func testDomainInitializerIgnoresNonNumericPortTail() {
        let configuration = CallWaveConfiguration(
            domain: "sip.example.com:sip",
            username: "1001", password: "secret", includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.host, "sip.example.com:sip")
        XCTAssertEqual(configuration.port, 0)
    }

    func testHostAndUsernameAreTrimmed() {
        let configuration = CallWaveConfiguration(
            host: "  sip.example.com \n", port: 0, transport: .UDP,
            username: " 1001 ", password: "  secret  ", includesCallsInRecents: false
        )

        XCTAssertEqual(configuration.host, "sip.example.com")
        XCTAssertEqual(configuration.username, "1001")
        // A password may legitimately begin or end with a space.
        XCTAssertEqual(configuration.password, "  secret  ")
    }

    // MARK: - Builder

    func testBuilderAppliesDocumentedDefaults() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
        }

        XCTAssertEqual(configuration.authenticationUsername, "1001")
        XCTAssertEqual(configuration.realm, "*")
        XCTAssertNil(configuration.outboundProxy)
        XCTAssertEqual(configuration.registrationExpiry, 300)
        XCTAssertEqual(configuration.keepAliveInterval, 15)
        XCTAssertEqual(configuration.mediaEncryption, .disabled)
        XCTAssertEqual(configuration.sessionTimersMode, .optional)
        XCTAssertEqual(configuration.sessionTimerInterval, 1800)
        XCTAssertEqual(configuration.sessionTimerMinimum, 90)
        XCTAssertTrue(configuration.additionalRegistrationHeaders.isEmpty)
    }

    func testBuilderKeepsExplicitValues() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.authenticationUsername = "auth-1001"
            builder.realm = "example.com"
            builder.outboundProxy = "sip:proxy.example.com;transport=tcp"
            builder.registrationExpiry = 120
            builder.keepAliveInterval = 30
            builder.mediaEncryption = .mandatory
            builder.additionalRegistrationHeaders = ["X-Tenant": "42"]
        }

        XCTAssertEqual(configuration.authenticationUsername, "auth-1001")
        XCTAssertEqual(configuration.realm, "example.com")
        XCTAssertEqual(configuration.outboundProxy, "sip:proxy.example.com;transport=tcp")
        XCTAssertEqual(configuration.registrationExpiry, 120)
        XCTAssertEqual(configuration.keepAliveInterval, 30)
        XCTAssertEqual(configuration.mediaEncryption, .mandatory)
        XCTAssertEqual(configuration.additionalRegistrationHeaders["X-Tenant"], "42")
    }

    func testBuilderKeepsSessionTimerValues() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.sessionTimersMode = .always
            builder.sessionTimerInterval = 600
            builder.sessionTimerMinimum = 120
        }

        XCTAssertEqual(configuration.sessionTimersMode, .always)
        XCTAssertEqual(configuration.sessionTimerInterval, 600)
        XCTAssertEqual(configuration.sessionTimerMinimum, 120)
    }

    func testSessionTimerMinimumIsClampedToTheRFCMinimum() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.sessionTimerMinimum = 30
        }

        XCTAssertEqual(configuration.sessionTimerMinimum, 90)
    }

    func testSessionTimerIntervalIsNeverBelowMinimum() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.sessionTimerInterval = 60
            builder.sessionTimerMinimum = 120
        }

        XCTAssertEqual(configuration.sessionTimerInterval, 120)
        XCTAssertEqual(configuration.sessionTimerMinimum, 120)
    }

    func testSessionTimerValuesFitPJSIPUnsignedFields() {
        let configuration = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.sessionTimerInterval = .max
            builder.sessionTimerMinimum = .max
        }

        XCTAssertEqual(configuration.sessionTimerInterval, UInt(UInt32.max))
        XCTAssertEqual(configuration.sessionTimerMinimum, UInt(UInt32.max))
    }

    func testApplyingChangesOneFieldAndKeepsTheRest() {
        let original = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.registrationExpiry = 120
        }

        let updated = original.applying { $0.password = "rotated" }

        XCTAssertEqual(updated.password, "rotated")
        XCTAssertEqual(updated.host, "sip.example.com")
        XCTAssertEqual(updated.registrationExpiry, 120)
        XCTAssertEqual(original.password, "secret", "the original must not be mutated")
    }

    // MARK: - Equality

    func testEqualityIgnoresRecentsButComparesCredentials() {
        let lhs = CallWaveConfiguration(
            host: "sip.example.com", port: 5060, transport: .UDP,
            username: "1001", password: "secret", includesCallsInRecents: false
        )
        let sameAccountDifferentRecents = CallWaveConfiguration(
            host: "sip.example.com", port: 5060, transport: .UDP,
            username: "1001", password: "secret", includesCallsInRecents: true
        )
        let rotatedPassword = CallWaveConfiguration(
            host: "sip.example.com", port: 5060, transport: .UDP,
            username: "1001", password: "rotated", includesCallsInRecents: false
        )

        XCTAssertTrue(lhs.isEqual(to: sameAccountDifferentRecents))
        XCTAssertFalse(lhs.isEqual(sameAccountDifferentRecents))
        XCTAssertFalse(lhs.isEqual(to: rotatedPassword))
    }

    func testEqualityComparesAccountLevelSettings() {
        let plain = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
        }
        let encrypted = plain.applying { $0.mediaEncryption = .mandatory }
        let proxied = plain.applying { $0.outboundProxy = "sip:proxy.example.com" }
        let timed = plain.applying { $0.sessionTimersMode = .always }

        XCTAssertFalse(plain.isEqual(to: encrypted))
        XCTAssertFalse(plain.isEqual(to: proxied))
        XCTAssertFalse(plain.isEqual(to: timed))
        XCTAssertTrue(plain.isEqual(to: plain.applying { _ in }))
    }

    func testApplyingPreservesSessionTimerSettings() {
        let timed = CallWaveConfiguration { builder in
            builder.host = "sip.example.com"
            builder.username = "1001"
            builder.password = "secret"
            builder.sessionTimersMode = .required
            builder.sessionTimerInterval = 900
            builder.sessionTimerMinimum = 180
        }

        let rotated = timed.applying { $0.password = "rotated" }

        XCTAssertEqual(rotated.sessionTimersMode, .required)
        XCTAssertEqual(rotated.sessionTimerInterval, 900)
        XCTAssertEqual(rotated.sessionTimerMinimum, 180)
    }

    func testEqualityAgainstNilIsFalse() {
        let configuration = CallWaveConfiguration(
            host: "sip.example.com", port: 0, transport: .UDP,
            username: "1001", password: "secret", includesCallsInRecents: false
        )

        XCTAssertFalse(configuration.isEqual(to: nil))
    }
}
