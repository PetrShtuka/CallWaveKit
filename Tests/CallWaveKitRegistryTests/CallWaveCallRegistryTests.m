#import <XCTest/XCTest.h>

#import "CallWaveCallRegistry.h"

/// `CallWaveCallRegistry` is a private header, so these live in an
/// Objective-C target that reaches it through a header search path rather than
/// through the module. Nothing here is public API.
@interface CallWaveCallRegistryCancellationTests : XCTestCase
@end

@implementation CallWaveCallRegistryCancellationTests {
    CallWaveCallRegistry *_registry;
}

- (void)setUp {
    [super setUp];
    _registry = [[CallWaveCallRegistry alloc] init];
}

/// A call announced by a push, with no INVITE yet — the state the bug happens in.
- (CallWaveCall *)pendingCall {
    return [_registry registerCallWithUUID:[NSUUID UUID]];
}

#pragma mark - Marking a cancellation

- (void)testCancellingAPendingCallKeepsTheRecord {
    CallWaveCall *call = [self pendingCall];

    XCTAssertTrue([_registry markCallCancelledBeforeInvite:call.uuid]);

    // Removing it is what used to let the late INVITE look like a fresh call.
    XCTAssertNotNil([_registry callForUUID:call.uuid]);
    XCTAssertEqual(_registry.count, (NSUInteger)1);
    XCTAssertTrue([_registry callForUUID:call.uuid].isCancelledBeforeInvite);
    XCTAssertNotNil([_registry callForUUID:call.uuid].cancelledAt);
}

- (void)testCancellingAnUnknownCallChangesNothing {
    XCTAssertFalse([_registry markCallCancelledBeforeInvite:[NSUUID UUID]]);
    XCTAssertFalse([_registry markCallCancelledBeforeInvite:nil]);
    XCTAssertEqual(_registry.count, (NSUInteger)0);
}

- (void)testACallWithAnInviteIsNotMarked {
    CallWaveCall *call = [self pendingCall];
    [_registry bindCallId:7 toUUID:call.uuid];

    // There is a real INVITE to reject through PJSUA, so nothing is deferred.
    XCTAssertFalse([_registry markCallCancelledBeforeInvite:call.uuid]);
    XCTAssertFalse([_registry callForUUID:call.uuid].isCancelledBeforeInvite);
}

- (void)testMarkingTwiceDoesNotExtendTheDeadline {
    CallWaveCall *call = [self pendingCall];

    XCTAssertTrue([_registry markCallCancelledBeforeInvite:call.uuid]);
    NSDate *first = [_registry callForUUID:call.uuid].cancelledAt;

    XCTAssertFalse([_registry markCallCancelledBeforeInvite:call.uuid]);
    XCTAssertEqualObjects([_registry callForUUID:call.uuid].cancelledAt, first);
}

#pragma mark - A cancelled call is not awaiting an INVITE

- (void)testCancelledCallIsNotReturnedAsAwaitingInvite {
    CallWaveCall *call = [self pendingCall];
    XCTAssertEqualObjects([_registry callAwaitingInvite].uuid, call.uuid);

    [_registry markCallCancelledBeforeInvite:call.uuid];

    // Matching an INVITE to it would ring a call the user already rejected.
    XCTAssertNil([_registry callAwaitingInvite]);
}

- (void)testCancellingOneCallLeavesAnotherAwaitingInvite {
    CallWaveCall *cancelled = [self pendingCall];
    CallWaveCall *live = [self pendingCall];

    [_registry markCallCancelledBeforeInvite:cancelled.uuid];

    XCTAssertEqualObjects([_registry callAwaitingInvite].uuid, live.uuid);
}

#pragma mark - Consuming a cancellation

- (void)testTakingACancellationReturnsItAndRemovesTheRecord {
    CallWaveCall *call = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:call.uuid];

    CallWaveCall *taken = [_registry takeCallCancelledBeforeInviteWithin:60];

    XCTAssertEqualObjects(taken.uuid, call.uuid);
    XCTAssertNil([_registry callForUUID:call.uuid]);
    XCTAssertEqual(_registry.count, (NSUInteger)0);
    // Once consumed it must not reject a second INVITE.
    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:60]);
}

- (void)testNothingIsTakenWhenNoCallWasCancelled {
    [self pendingCall];

    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:60]);
    XCTAssertEqual(_registry.count, (NSUInteger)1);
}

- (void)testALiveCallAwaitingItsInviteTakesPrecedence {
    CallWaveCall *cancelled = [self pendingCall];
    CallWaveCall *live = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:cancelled.uuid];

    // The arriving INVITE may belong to `live`; refusing it would drop a call
    // the user never rejected.
    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:60]);
    XCTAssertNotNil([_registry callForUUID:cancelled.uuid]);
    XCTAssertNotNil([_registry callForUUID:live.uuid]);
}

- (void)testTheOldestCancellationIsTakenFirst {
    CallWaveCall *first = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:first.uuid];
    usleep(20000);
    CallWaveCall *second = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:second.uuid];

    XCTAssertEqualObjects([_registry takeCallCancelledBeforeInviteWithin:60].uuid, first.uuid);
    XCTAssertEqualObjects([_registry takeCallCancelledBeforeInviteWithin:60].uuid, second.uuid);
}

#pragma mark - Expiry

- (void)testAnExpiredCancellationIsEquivalentToNoRecord {
    CallWaveCall *call = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:call.uuid];
    usleep(20000);

    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:0.01]);
    // And it is dropped, so it cannot reject some later, unrelated call.
    XCTAssertNil([_registry callForUUID:call.uuid]);
    XCTAssertEqual(_registry.count, (NSUInteger)0);
}

- (void)testAFreshCancellationSurvivesTheSameWindow {
    CallWaveCall *call = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:call.uuid];

    XCTAssertEqualObjects([_registry takeCallCancelledBeforeInviteWithin:60].uuid, call.uuid);
}

- (void)testExpiryDoesNotDisturbACallStillAwaitingItsInvite {
    CallWaveCall *cancelled = [self pendingCall];
    [_registry markCallCancelledBeforeInvite:cancelled.uuid];
    usleep(20000);
    CallWaveCall *live = [self pendingCall];

    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:0.01]);
    XCTAssertNil([_registry callForUUID:cancelled.uuid]);
    XCTAssertNotNil([_registry callForUUID:live.uuid]);
    XCTAssertEqualObjects([_registry callAwaitingInvite].uuid, live.uuid);
}

#pragma mark - Calls with a SIP id are untouched

- (void)testAnAnsweredCallIsNeverConsumedAsACancellation {
    CallWaveCall *answered = [self pendingCall];
    [_registry bindCallId:3 toUUID:answered.uuid];
    answered.state = CallWaveCallStateActive;

    XCTAssertNil([_registry takeCallCancelledBeforeInviteWithin:60]);
    XCTAssertEqualObjects([_registry callForCallId:3].uuid, answered.uuid);
}

@end
