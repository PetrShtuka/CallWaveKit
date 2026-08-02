import XCTest

@testable import CallWaveKit
@testable import CallWaveKitAsync

final class CallWaveAsyncTests: XCTestCase {

    private func makeClient() -> CallWaveClient {
        CallWaveClient(
            configuration: nil,
            options: [],
            provider: nil,
            engineConfiguration: nil
        )
    }

    func testEventStreamStopsWhenTheConsumingTaskIsCancelled() async {
        let client = makeClient()
        let started = expectation(description: "consumer started")

        let consumer = Task {
            started.fulfill()
            for await _ in client.events {
                XCTFail("no event is emitted by an idle client")
            }
        }

        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        _ = await consumer.value
    }

    func testWaitUntilRegisteredTimesOutOnAnIdleClient() async {
        let client = makeClient()

        do {
            try await client.waitUntilRegistered(timeout: 0.2)
            XCTFail("an unstarted client never registers")
        } catch let error as CallWaveAsyncError {
            XCTAssertEqual(error, .registrationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPerCallStreamIgnoresOtherCalls() async {
        let client = makeClient()
        let unrelated = UUID()

        // Nothing is emitted, but the stream must still be constructible and
        // must tear its observer down cleanly.
        let stream = client.events(forCallWithUUID: unrelated)
        let consumer = Task {
            for await _ in stream {
                XCTFail("no event is emitted by an idle client")
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        _ = await consumer.value
    }
}
