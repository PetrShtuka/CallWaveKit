import XCTest

@testable import CallWaveKit

final class CallWaveCallerNameTests: XCTestCase {

    func testQuotedDisplayNameWins() {
        XCTAssertEqual(
            CallWaveClient.displayName(forCaller: "\"Front Door\" <sip:101@10.0.0.5>"),
            "Front Door"
        )
    }

    func testUserPartIsUsedWhenThereIsNoDisplayName() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "<sip:101@10.0.0.5>"), "101")
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "sip:101@10.0.0.5"), "101")
    }

    func testSIPSchemeIsMatchedCaseInsensitively() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "<SIP:101@10.0.0.5>"), "101")
    }

    func testEmptyQuotedNameFallsThroughToUserPart() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "\"\" <sip:101@10.0.0.5>"), "101")
    }

    func testUnparseableValueIsReturnedVerbatim() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "Front Door"), "Front Door")
    }

    func testEmptyAndNilInputProduceAnEmptyName() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: ""), "")
        XCTAssertEqual(CallWaveClient.displayName(forCaller: nil), "")
    }

    func testURIWithoutHostIsReturnedVerbatim() {
        XCTAssertEqual(CallWaveClient.displayName(forCaller: "sip:101"), "sip:101")
    }
}

final class CallWaveDTMFNormalizationTests: XCTestCase {

    func testDigitsAndControlCharactersSurvive() {
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("0123456789*#"), "0123456789*#")
    }

    func testLetterKeysAreUppercased() {
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("abcd"), "ABCD")
    }

    func testUnsupportedCharactersAreDropped() {
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("1-2 3(4)"), "1234")
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("e f g"), "")
    }

    func testMultiByteInputIsDroppedRatherThanTruncated() {
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("1️⃣2"), "2")
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits("дверь"), "")
    }

    func testEmptyAndNilInputProduceAnEmptyString() {
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits(""), "")
        XCTAssertEqual(CallWaveClient.normalizedDTMFDigits(nil), "")
    }
}

final class CallWaveClientPropertyTests: XCTestCase {

    /// Host-owned mode so the test bundle never creates a `CXProvider` or a
    /// `PKPushRegistry`, neither of which belongs in a unit test process.
    private func makeClient(
        engine: CallWaveEngineConfiguration? = nil
    ) -> CallWaveClient {
        CallWaveClient(
            configuration: nil,
            options: [],
            provider: nil,
            engineConfiguration: engine
        )
    }

    func testAcceptDelayIsClampedToTheDocumentedRange() {
        let client = makeClient()

        XCTAssertEqual(client.acceptDelay, 0.5, accuracy: 0.0001)

        client.acceptDelay = -1
        XCTAssertEqual(client.acceptDelay, 0, accuracy: 0.0001)

        client.acceptDelay = 5
        XCTAssertEqual(client.acceptDelay, 1.0, accuracy: 0.0001)

        client.acceptDelay = .nan
        XCTAssertEqual(client.acceptDelay, 0, accuracy: 0.0001)

        client.acceptDelay = 0.25
        XCTAssertEqual(client.acceptDelay, 0.25, accuracy: 0.0001)
    }

    func testIncomingCallTimeoutTreatsNonPositiveValuesAsDisabled() {
        let client = makeClient()

        XCTAssertEqual(client.incomingCallTimeout, 60, accuracy: 0.0001)

        client.incomingCallTimeout = 0
        XCTAssertEqual(client.incomingCallTimeout, 0, accuracy: 0.0001)

        client.incomingCallTimeout = -5
        XCTAssertEqual(client.incomingCallTimeout, 0, accuracy: 0.0001)

        client.incomingCallTimeout = 30
        XCTAssertEqual(client.incomingCallTimeout, 30, accuracy: 0.0001)
    }

    func testPushCompletionTimeoutFallsBackToTheDefault() {
        let client = makeClient()

        XCTAssertEqual(client.pushCompletionTimeout, 4, accuracy: 0.0001)

        client.pushCompletionTimeout = 0
        XCTAssertEqual(client.pushCompletionTimeout, 4, accuracy: 0.0001)

        client.pushCompletionTimeout = 2
        XCTAssertEqual(client.pushCompletionTimeout, 2, accuracy: 0.0001)
    }

    func testDefaultCallerNameNeverBecomesEmpty() {
        let client = makeClient()

        XCTAssertEqual(client.defaultCallerName, "Unknown")

        // Deliberately non-ASCII: the name reaches CallKit and a host that
        // localizes it must get its own string back unchanged.
        client.defaultCallerName = "Домофон"
        XCTAssertEqual(client.defaultCallerName, "Домофон")

        client.defaultCallerName = ""
        XCTAssertEqual(client.defaultCallerName, "Unknown")
    }

    func testHostOwnedModeCreatesNoProvider() {
        let client = makeClient()

        XCTAssertNil(client.provider)
        XCTAssertFalse(client.isRunning)
        XCTAssertEqual(client.registrationState, .stopped)
        XCTAssertEqual(client.callState, .idle)
        XCTAssertTrue(client.activeCallUUIDs.isEmpty)
        XCTAssertNil(client.registrationError)
    }

    func testEngineConfigurationIsCopiedOnInitialisation() {
        let engine = CallWaveEngineConfiguration.defaultConfiguration()
        engine.maximumCalls = 2
        engine.preferredCodecs = ["PCMA/8000"]

        let client = makeClient(engine: engine)
        engine.maximumCalls = 9

        XCTAssertEqual(client.engineConfiguration.maximumCalls, 2)
        XCTAssertEqual(client.engineConfiguration.preferredCodecs, ["PCMA/8000"])
    }

    func testHoldIsRejectedWhenTheEngineOnlyAllowsOneCall() {
        let client = makeClient()
        let rejected = expectation(description: "hold rejected")

        client.setHeld(true) { error in
            XCTAssertEqual((error as NSError?)?.domain, CallWaveErrorDomain)
            XCTAssertEqual(
                (error as NSError?)?.code,
                CallWaveError.Code.unsupportedOperation.rawValue
            )
            rejected.fulfill()
        }

        wait(for: [rejected], timeout: 2)
    }

    func testCallActionsWithoutACallReportNoActiveCall() {
        let client = makeClient()
        let failed = expectation(description: "end call rejected")

        client.endCall(uuid: nil) { error in
            XCTAssertEqual(
                (error as NSError?)?.code,
                CallWaveError.Code.noActiveCall.rawValue
            )
            failed.fulfill()
        }

        wait(for: [failed], timeout: 2)
    }

    func testDTMFWithNoSendableDigitsIsRejectedBeforeTouchingTheStack() {
        let client = makeClient()
        let failed = expectation(description: "DTMF rejected")

        client.sendDTMF("---") { error in
            XCTAssertEqual(
                (error as NSError?)?.code,
                CallWaveError.Code.invalidArgument.rawValue
            )
            failed.fulfill()
        }

        wait(for: [failed], timeout: 2)
    }

    func testStartingWithoutAConfigurationReportsNotConfigured() {
        let client = makeClient()

        XCTAssertThrowsError(try client.start()) { error in
            XCTAssertEqual((error as NSError).code, CallWaveError.Code.notConfigured.rawValue)
        }
    }
}

final class CallWaveEngineConfigurationTests: XCTestCase {

    func testDefaultsMatchTheDocumentedValues() {
        let engine = CallWaveEngineConfiguration.defaultConfiguration()

        XCTAssertEqual(engine.maximumCalls, 1)
        XCTAssertEqual(engine.logLevel, .warning)
        XCTAssertFalse(engine.isICEEnabled)
        XCTAssertTrue(engine.stunServers.isEmpty)
        XCTAssertTrue(engine.preferredCodecs.isEmpty)
        XCTAssertTrue(engine.verifiesTLSCertificate)
        XCTAssertEqual(engine.echoCancellationTailMilliseconds, 200)
        XCTAssertFalse(engine.isVoiceActivityDetectionEnabled)
        XCTAssertTrue(engine.handlesNetworkChanges)
    }

    func testMaximumCallsNeverDropsBelowOne() {
        let engine = CallWaveEngineConfiguration.defaultConfiguration()

        engine.maximumCalls = 0
        XCTAssertEqual(engine.maximumCalls, 1)

        engine.maximumCalls = 4
        XCTAssertEqual(engine.maximumCalls, 4)
    }

    func testCopyIsIndependent() {
        let engine = CallWaveEngineConfiguration.defaultConfiguration()
        engine.maximumCalls = 3
        engine.userAgent = "CallWave/1.0"

        // swiftlint:disable:next force_cast
        let copy = engine.copy() as! CallWaveEngineConfiguration
        engine.maximumCalls = 1
        engine.userAgent = "changed"

        XCTAssertEqual(copy.maximumCalls, 3)
        XCTAssertEqual(copy.userAgent, "CallWave/1.0")
    }
}
