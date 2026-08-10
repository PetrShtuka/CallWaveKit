#import <XCTest/XCTest.h>

#import "CallWaveClient.h"
#import "CallWaveCallRegistry.h"

// `takeCallCancelledBeforeInvite` is the exact decision point the PJSIP
// `on_incoming_call` callback consults before answering a late INVITE with
// `603 Decline`. It is private, so the chain tests drive it through a
// test-only category; the PJSIP side of the chain — a static C callback that
// needs a running stack — stays on the device/integration checklist.
@interface CallWaveClient (PushCancelInviteChainTests)
@property (nonatomic, strong) CallWaveCallRegistry *registry;
- (nullable CallWaveCall *)takeCallCancelledBeforeInvite;
@end

@interface CallWavePushCancelInviteChainTests : XCTestCase
@property (nonatomic, strong) CallWaveClient *client;
@end

@implementation CallWavePushCancelInviteChainTests

- (void)setUp {
    [super setUp];
    // Host-owned CallKit: no CXProvider and no PKPushRegistry in a test
    // process, while the push/parsing/registry chain under test is identical.
    self.client = [[CallWaveClient alloc] initWithConfiguration:nil
                                                        options:CallWaveIntegrationOptionNone
                                                       provider:nil
                                            engineConfiguration:nil];
}

- (void)tearDown {
    self.client = nil;
    [super tearDown];
}

/// Pushes a payload through the managed-PushKit entry point and waits for its
/// completion, like PushKit would.
- (void)push:(NSDictionary *)payload {
    XCTestExpectation *acknowledged = [self expectationWithDescription:@"push acknowledged"];
    [self.client handleVoIPPushPayload:payload completion:^{
        [acknowledged fulfill];
    }];
    [self waitForExpectations:@[acknowledged] timeout:2];
}

- (NSDictionary *)announcementForUUID:(NSUUID *)uuid {
    return @{@"data": @{@"uuid": uuid.UUIDString, @"callerID": @"101"}};
}

- (NSDictionary *)cancellationForUUID:(NSUUID *)uuid {
    return @{@"data": @{@"uuid": uuid.UUIDString, @"type": @"cancel"}};
}

- (void)testPushThenCancelThenLateInviteIsRefused {
    NSUUID *uuid = [NSUUID UUID];
    [self push:[self announcementForUUID:uuid]];
    XCTAssertEqual(self.client.callState, CallWaveCallStateIncoming);

    [self push:[self cancellationForUUID:uuid]];
    XCTAssertEqual(self.client.callState, CallWaveCallStateEnded);

    // The late INVITE lands: `on_incoming_call` takes the cancellation and
    // answers 603 instead of ringing.
    CallWaveCall *cancelled = [self.client takeCallCancelledBeforeInvite];
    XCTAssertEqualObjects(cancelled.uuid, uuid);

    // The cancellation is consumed: a further, unrelated INVITE must not be
    // refused by the same record.
    XCTAssertNil([self.client takeCallCancelledBeforeInvite]);
}

- (void)testCancelThatOvertakesTheAnnouncementStillRefusesTheInvite {
    NSUUID *uuid = [NSUUID UUID];
    [self push:[self cancellationForUUID:uuid]];

    // The announcement push that lost the race must not ring.
    [self push:[self announcementForUUID:uuid]];
    XCTAssertEqual(self.client.callState, CallWaveCallStateEnded);

    // …and its INVITE must still be refused.
    CallWaveCall *cancelled = [self.client takeCallCancelledBeforeInvite];
    XCTAssertEqualObjects(cancelled.uuid, uuid);
}

- (void)testPendingInviteTakesPrecedenceOverAPendingCancellation {
    NSUUID *first = [NSUUID UUID];
    NSUUID *second = [NSUUID UUID];
    [self push:[self announcementForUUID:first]];
    [self push:[self announcementForUUID:second]];
    [self push:[self cancellationForUUID:second]];

    // `first` is still legitimately awaiting its INVITE, so an INVITE arriving
    // now must be matched to it — not consumed by `second`'s cancellation.
    XCTAssertNil([self.client takeCallCancelledBeforeInvite]);

    // `first`'s INVITE arrives and is bound by `handleIncomingSIPCall:caller:`;
    // simulate that binding.
    [self.client.registry bindCallId:7 toUUID:first];

    // The next INVITE belongs to the cancelled call and is refused.
    CallWaveCall *cancelled = [self.client takeCallCancelledBeforeInvite];
    XCTAssertEqualObjects(cancelled.uuid, second);
}

- (void)testCancellationExpiresBeforeTheInvite {
    NSUUID *uuid = [NSUUID UUID];
    [self push:[self announcementForUUID:uuid]];
    [self push:[self cancellationForUUID:uuid]];

    // A cancellation older than the window is dead weight: it is dropped and
    // cannot refuse an INVITE that arrives too late to belong to it.
    XCTAssertNil([self.client.registry takeCallCancelledBeforeInviteWithin:0]);
    XCTAssertNil([self.client.registry takeCallCancelledBeforeInviteWithin:60]);
}

@end
