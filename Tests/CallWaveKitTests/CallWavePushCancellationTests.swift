import XCTest

@testable import CallWaveKit

/// Managed-PushKit payload handling: incoming pushes, duplicate pushes and
/// remote cancellations, all in host-owned CallKit mode so the test process
/// never creates a `CXProvider` or a `PKPushRegistry`.
final class CallWavePushCancellationTests: XCTestCase {

    private var client: CallWaveClient!
    private var events: [CallWaveEvent] = []
    private var observer: (NSCopying & NSObjectProtocol)?

    override func setUp() {
        super.setUp()
        events = []
        client = CallWaveClient(
            configuration: nil,
            options: [],
            provider: nil,
            engineConfiguration: nil
        )
        observer = client.addEventObserver { [weak self] event in
            self?.events.append(event)
        }
    }

    override func tearDown() {
        if let observer {
            client.removeEventObserver(observer)
        }
        client = nil
        super.tearDown()
    }

    private func push(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let acknowledged = expectation(description: "push acknowledged")
        client.handleVoIPPushPayload(payload) {
            acknowledged.fulfill()
        }
        wait(for: [acknowledged], timeout: 2)
    }

    private func incomingPayload(uuid: UUID) -> [String: Any] {
        ["data": ["uuid": uuid.uuidString, "callerID": "101"]]
    }

    private func states() -> [CallWaveCallState] {
        events.compactMap { $0.type == .callStateChanged ? $0.callState : nil }
    }

    func testCancellationPushAfterReportedCallEndsItBeforeInvite() {
        let uuid = UUID()
        push(incomingPayload(uuid: uuid))
        XCTAssertEqual(client.callState, .incoming)

        push(["data": ["uuid": uuid.uuidString, "type": "cancel"]])

        XCTAssertEqual(client.callState, .ended)
        XCTAssertEqual(states(), [.incoming, .ended])
        let ended = events.first { $0.type == .callEnded }
        XCTAssertEqual(ended?.callUUID, uuid)
        XCTAssertEqual(ended?.endedReason, .remoteEnded)
    }

    func testCancellationMarkersAreRecognisedCaseInsensitively() {
        for marker in ["cancel", "cancelled", "cancellation", "CANCEL"] {
            let uuid = UUID()
            push(incomingPayload(uuid: uuid))
            push(["data": ["uuid": uuid.uuidString, "event": marker]])
            XCTAssertEqual(client.callState, .ended, "marker \(marker) was not recognised")
        }
    }

    func testCancellationPushForUnknownCallLeavesATombstone() {
        let uuid = UUID()
        push(["data": ["uuid": uuid.uuidString, "type": "cancel"]])

        // The cancellation overtook the announcement push: a tombstone is kept
        // so neither that push nor a late INVITE can ring.
        XCTAssertEqual(client.callState, .ended)
        let ended = events.first { $0.type == .callEnded }
        XCTAssertEqual(ended?.callUUID, uuid)
        XCTAssertEqual(ended?.endedReason, .remoteEnded)

        events.removeAll()
        push(incomingPayload(uuid: uuid))
        XCTAssertFalse(states().contains(.incoming),
                       "the announcement push that lost the race must not ring")
    }

    func testCancellationPushIsNeverReportedAsANewIncomingCall() {
        // A lone cancellation must not flash an incoming-call screen — this is
        // the regression the managed-PushKit mode had: every payload was
        // treated as a new call.
        push(["data": ["uuid": UUID().uuidString, "type": "cancel"]])

        XCTAssertFalse(states().contains(.incoming))
    }

    func testDuplicateIncomingPushReportsTheCallOnlyOnce() {
        let uuid = UUID()
        push(incomingPayload(uuid: uuid))
        push(incomingPayload(uuid: uuid))

        XCTAssertEqual(client.callState, .incoming)
        XCTAssertEqual(states().filter { $0 == .incoming }.count, 1)
    }

    func testCustomParserCanMarkAPayloadAsCancellation() {
        let uuid = UUID()
        client.pushPayloadParser = { payload in
            guard let id = (payload["call_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return nil
            }
            if payload["hangup"] as? Bool == true {
                return CallWaveIncomingCallDescriptor.cancellationDescriptor(with: id)
            }
            return CallWaveIncomingCallDescriptor(uuid: id, caller: nil)
        }

        push(["call_id": uuid.uuidString])
        XCTAssertEqual(client.callState, .incoming)

        push(["call_id": uuid.uuidString, "hangup": true])
        XCTAssertEqual(client.callState, .ended)
        let ended = events.first { $0.type == .callEnded }
        XCTAssertEqual(ended?.callUUID, uuid)
        XCTAssertEqual(ended?.endedReason, .remoteEnded)
    }
}
