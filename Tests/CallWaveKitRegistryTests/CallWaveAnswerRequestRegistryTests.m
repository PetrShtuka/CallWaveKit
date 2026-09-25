#import <XCTest/XCTest.h>

#import "CallWaveAnswerTimeline.h"
#import "CallWaveCallRegistry.h"

/// An answer the host asked for before the INVITE was there is kept by the
/// registry, under the same lock that binds INVITEs, so the binding can answer
/// it without anyone polling. These pin the hand-off: every request ends up
/// with exactly one owner.
@interface CallWaveAnswerRequestRegistryTests : XCTestCase
@end

@implementation CallWaveAnswerRequestRegistryTests {
    CallWaveCallRegistry *_registry;
}

- (void)setUp {
    [super setUp];
    _registry = [[CallWaveCallRegistry alloc] init];
}

- (void)testARequestWaitsForTheBindingAndIsHandedToIt {
    NSUUID *uuid = [_registry registerCallWithUUID:[NSUUID UUID]].uuid;
    NSObject *request = [NSObject new];

    XCTAssertEqual([_registry addAnswerRequest:request forUUID:uuid], CallWaveSIPCallIdInvalid);

    NSArray *taken = [_registry bindCallId:4 toUUID:uuid];
    XCTAssertEqual(taken.count, 1u);
    XCTAssertTrue(taken.firstObject == request);
    XCTAssertEqual([_registry bindCallId:4 toUUID:uuid].count, 0u,
                   @"a request is handed over once");
}

- (void)testARequestForABoundCallIsNotKept {
    NSUUID *uuid = [_registry registerCallWithUUID:[NSUUID UUID]].uuid;
    [_registry bindCallId:0 toUUID:uuid];
    NSObject *request = [NSObject new];

    // Call id 0 is valid; a nil lookup reading 0 would look exactly like this,
    // which is why the unbound case above has to come back invalid.
    XCTAssertEqual([_registry addAnswerRequest:request forUUID:uuid], 0);
    XCTAssertFalse([_registry removeAnswerRequest:request forUUID:uuid]);
    XCTAssertEqual([_registry takeAnswerRequestsForUUID:uuid].count, 0u);
}

- (void)testARequestForAnUnknownCallWaitsForIt {
    NSUUID *uuid = [NSUUID UUID];
    NSObject *request = [NSObject new];

    XCTAssertEqual([_registry addAnswerRequest:request forUUID:uuid], CallWaveSIPCallIdInvalid);
    XCTAssertNil([_registry callForUUID:uuid], @"answering must not invent a call");

    NSArray *taken = [_registry bindCallId:2 toUUID:uuid];
    XCTAssertTrue(taken.firstObject == request);
}

- (void)testRemovingARequestMakesTheCallerItsOnlyOwner {
    NSUUID *uuid = [_registry registerCallWithUUID:[NSUUID UUID]].uuid;
    NSObject *first = [NSObject new];
    NSObject *second = [NSObject new];
    [_registry addAnswerRequest:first forUUID:uuid];
    [_registry addAnswerRequest:second forUUID:uuid];

    XCTAssertTrue([_registry removeAnswerRequest:first forUUID:uuid]);
    XCTAssertFalse([_registry removeAnswerRequest:first forUUID:uuid]);

    NSArray *taken = [_registry bindCallId:3 toUUID:uuid];
    XCTAssertEqual(taken.count, 1u);
    XCTAssertTrue(taken.firstObject == second);
}

- (void)testRemovingTheCallLeavesItsRequestsToBeCollected {
    NSUUID *uuid = [_registry registerCallWithUUID:[NSUUID UUID]].uuid;
    NSObject *request = [NSObject new];
    [_registry addAnswerRequest:request forUUID:uuid];

    [_registry removeCallWithUUID:uuid];
    [_registry removeAllCalls];

    // Dropping it silently would leave a completion that never runs.
    NSArray *all = [_registry takeAllAnswerRequests];
    XCTAssertEqual(all.count, 1u);
    XCTAssertTrue(all.firstObject == request);
    XCTAssertEqual([_registry takeAllAnswerRequests].count, 0u);
}

- (void)testBindingToTheCallAwaitingAnInviteTakesItsRequests {
    CallWaveCall *older = [_registry registerCallWithUUID:[NSUUID UUID]];
    [NSThread sleepForTimeInterval:0.002];
    CallWaveCall *newer = [_registry registerCallWithUUID:[NSUUID UUID]];
    NSObject *forNewer = [NSObject new];
    NSObject *forOlder = [NSObject new];
    [_registry addAnswerRequest:forNewer forUUID:newer.uuid];
    [_registry addAnswerRequest:forOlder forUUID:older.uuid];

    NSArray *taken = nil;
    CallWaveCall *bound = [_registry bindCallIdToCallAwaitingInvite:5 answerRequests:&taken];

    XCTAssertEqualObjects(bound.uuid, older.uuid);
    XCTAssertEqual(bound.callId, 5);
    XCTAssertEqual(taken.count, 1u);
    XCTAssertTrue(taken.firstObject == forOlder);
    XCTAssertEqual([_registry takeAnswerRequestsForUUID:newer.uuid].count, 1u);
}

- (void)testACancelledCallIsNotBoundToALateInvite {
    CallWaveCall *call = [_registry registerCallWithUUID:[NSUUID UUID]];
    XCTAssertTrue([_registry markCallCancelledBeforeInvite:call.uuid]);

    NSArray *taken = nil;
    XCTAssertNil([_registry bindCallIdToCallAwaitingInvite:1 answerRequests:&taken]);
    XCTAssertEqual(taken.count, 0u);
    XCTAssertEqual(call.callId, CallWaveSIPCallIdInvalid);
}

/// The race the lock exists for: the host answering on its thread while
/// PJSIP binds the INVITE on its own. Whichever wins, the answer is either
/// told the call id or handed to the binding — never neither, never both.
- (void)testAnAnswerRacingTheBindingAlwaysHasExactlyOneOwner {
    dispatch_queue_t host = dispatch_queue_create("host", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t pjsip = dispatch_queue_create("pjsip", DISPATCH_QUEUE_SERIAL);
    for (NSUInteger round = 0; round < 2000; round++) {
        CallWaveCallRegistry *registry = [[CallWaveCallRegistry alloc] init];
        NSUUID *uuid = [registry registerCallWithUUID:[NSUUID UUID]].uuid;
        NSObject *request = [NSObject new];
        __block CallWaveSIPCallId seenByHost = CallWaveSIPCallIdInvalid;
        __block NSArray *takenByBinding = nil;

        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, host, ^{
            seenByHost = [registry addAnswerRequest:request forUUID:uuid];
        });
        dispatch_group_async(group, pjsip, ^{
            NSArray *taken = nil;
            [registry bindCallIdToCallAwaitingInvite:9 answerRequests:&taken];
            takenByBinding = taken;
        });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        BOOL hostAnswers = seenByHost == 9;
        BOOL bindingAnswers = takenByBinding.count == 1 && takenByBinding.firstObject == request;
        XCTAssertTrue(hostAnswers != bindingAnswers,
                      @"round %lu: host saw %d, binding took %lu", (unsigned long)round,
                      seenByHost, (unsigned long)takenByBinding.count);
        if (hostAnswers == bindingAnswers) {
            return;
        }
    }
}

@end

@interface CallWaveAnswerTimelineTests : XCTestCase
@end

@implementation CallWaveAnswerTimelineTests

- (void)testAMilestoneIsRecordedOnce {
    CallWaveAnswerTimeline *timeline = [CallWaveAnswerTimeline new];

    XCTAssertTrue([timeline recordMilestone:CallWaveAnswerMilestoneAnswerSent at:10]);
    XCTAssertFalse([timeline recordMilestone:CallWaveAnswerMilestoneAnswerSent at:20]);
    XCTAssertEqual([timeline timeOfMilestone:CallWaveAnswerMilestoneAnswerSent], 10u);
    XCTAssertFalse([timeline recordMilestone:CallWaveAnswerMilestoneMediaActive at:0],
                   @"0 means not yet and cannot be recorded");
}

- (void)testOffsetsAreRelativeToTheAnswer {
    CallWaveAnswerTimeline *timeline = [CallWaveAnswerTimeline new];
    [timeline recordMilestone:CallWaveAnswerMilestoneInviteReceived at:1000000];

    XCTAssertEqualObjects([timeline offsetOfMilestone:CallWaveAnswerMilestoneInviteReceived],
                          @"before acceptCall");
    XCTAssertEqualObjects([timeline offsetOfMilestone:CallWaveAnswerMilestoneAnswerSent],
                          @"not seen");

    [timeline recordMilestone:CallWaveAnswerMilestoneAnswerRequested at:41000000];
    [timeline recordMilestone:CallWaveAnswerMilestoneAnswerSent at:53000000];

    XCTAssertEqualObjects([timeline offsetOfMilestone:CallWaveAnswerMilestoneInviteReceived],
                          @"-40 ms");
    XCTAssertEqualObjects([timeline offsetOfMilestone:CallWaveAnswerMilestoneAnswerSent],
                          @"+12 ms");
    XCTAssertTrue([timeline.summary containsString:@"200 OK sent +12 ms"], @"%@", timeline.summary);
    XCTAssertTrue([timeline.summary containsString:@"audio connected not seen"], @"%@",
                  timeline.summary);
}

- (void)testTheClockNeverReadsAsNotYet {
    uint64_t first = CallWaveMonotonicNanoseconds();
    uint64_t second = CallWaveMonotonicNanoseconds();
    XCTAssertGreaterThan(first, 0u);
    XCTAssertGreaterThanOrEqual(second, first);
}

@end
