#import <XCTest/XCTest.h>

#import "CallWaveAnswerTimeline.h"
#import "CallWaveCallRegistry.h"
#import "CallWaveClient.h"
#import "CallWaveLoopbackIntercom.h"

#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

// The answer used to be polled for on the main queue every 250 ms, bound to
// its INVITE on the main queue, and paused another 500 ms on the main queue —
// on a cold start, the busiest queue in the process. In the field that added up
// to two seconds between the user answering and `200 OK`.
//
// These drive the real engine with a real INVITE over loopback, as the decline
// tests do, and measure on the wire: the socket is read on a thread of its own,
// so the arrival of `200 OK` is timed even while the test blocks the main
// thread to stand in for a busy launch.

/// On a loaded CI simulator an unhurried answer still takes a few
/// milliseconds; the old path took 250 at best.
static const double CallWaveAnswerBudgetMilliseconds = 50.0;

@interface CallWaveClient (AnswerLatencyTests)
@property (nonatomic, strong) CallWaveCallRegistry *registry;
@end

@interface CallWaveAnswerLatencyLog : NSObject <CallWaveLogger>
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@end

@implementation CallWaveAnswerLatencyLog
- (instancetype)init {
    self = [super init];
    if (self) {
        _messages = [NSMutableArray array];
    }
    return self;
}
- (void)callWaveDidLogMessage:(NSString *)message
                        level:(CallWaveLogLevel)level
                     category:(NSString *)category {
    @synchronized (self) {
        [self.messages addObject:message];
    }
}
- (NSUInteger)countOfMessagesContaining:(NSString *)needle {
    NSUInteger count = 0;
    @synchronized (self) {
        for (NSString *message in self.messages) {
            if ([message containsString:needle]) {
                count++;
            }
        }
    }
    return count;
}
- (nullable NSString *)messageContaining:(NSString *)needle {
    @synchronized (self) {
        for (NSString *message in self.messages) {
            if ([message containsString:needle]) {
                return message;
            }
        }
    }
    return nil;
}
@end

@interface CallWaveAnswerLatencyTests : XCTestCase
@property (nonatomic, strong, nullable) CallWaveClient *client;
@property (nonatomic, strong, nullable) CallWaveLoopbackIntercom *intercom;
@property (nonatomic, strong) CallWaveAnswerLatencyLog *log;
@property (nonatomic, assign) CallWaveLogLevel previousLevel;
@property (nonatomic, assign) BOOL previousRedaction;
@end

@implementation CallWaveAnswerLatencyTests

- (void)setUp {
    [super setUp];
    self.log = [CallWaveAnswerLatencyLog new];
    self.previousLevel = CallWaveLog.level;
    self.previousRedaction = CallWaveLog.isRedactingIdentifiers;
    CallWaveLog.level = CallWaveLogLevelInfo;
    CallWaveLog.redactsIdentifiers = NO;
    CallWaveLog.logger = self.log;
}

- (void)tearDown {
    [self.client stop];
    self.client = nil;
    [self.intercom close];
    self.intercom = nil;
    CallWaveLog.logger = nil;
    CallWaveLog.level = self.previousLevel;
    CallWaveLog.redactsIdentifiers = self.previousRedaction;
    [super tearDown];
}

#pragma mark - Harness

- (int)enginePort {
    pjsua_transport_id ids[8];
    unsigned count = (unsigned)(sizeof(ids) / sizeof(ids[0]));
    if (pjsua_enum_transports(ids, &count) != PJ_SUCCESS) {
        return 0;
    }
    for (unsigned i = 0; i < count; i++) {
        pjsua_transport_info info;
        if (pjsua_transport_get_info(ids[i], &info) == PJ_SUCCESS &&
            info.type == PJSIP_TRANSPORT_UDP && info.local_name.port != 0) {
            return info.local_name.port;
        }
    }
    return 0;
}

/// Host-owned CallKit, exactly as Majordom drives it: the push is reported by
/// the host and handed over with `-prepareIncomingCallWithUUID:caller:`.
- (BOOL)startEngine {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithHost:@"127.0.0.1"
                                               port:65530
                                          transport:CallWaveTransportUDP
                                           username:@"1001"
                                           password:@"not-a-real-credential"
                             includesCallsInRecents:NO];
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.handlesNetworkChanges = NO;
    engine.IPVersionPolicy = CallWaveIPVersionPolicyIPv4Only;
    engine.logLevel = CallWaveLogLevelInfo;
    self.client = [[CallWaveClient alloc] initWithConfiguration:configuration
                                                        options:CallWaveIntegrationOptionNone
                                                       provider:nil
                                            engineConfiguration:engine];
    // Keep the manual activation out of the measurement; it opens the sound
    // device, which a test process has no business doing.
    self.client.audioActivationFallbackDelay = 5;
    NSError *error = nil;
    if (![self.client startWithError:&error]) {
        XCTFail(@"engine did not start: %@", error);
        return NO;
    }
    int port = [self enginePort];
    if (port == 0) {
        XCTFail(@"no UDP transport to talk to");
        return NO;
    }
    self.intercom = [[CallWaveLoopbackIntercom alloc] initWithEnginePort:port];
    if (self.intercom == nil) {
        XCTFail(@"loopback UDP unavailable");
        return NO;
    }
    return YES;
}

- (NSString *)newCallId {
    return [NSString stringWithFormat:@"callwave-latency-%@", [NSUUID UUID].UUIDString];
}

- (uint64_t)timeOf:(CallWaveAnswerMilestone)milestone forUUID:(NSUUID *)uuid {
    return [[self.client.registry callForUUID:uuid].timeline timeOfMilestone:milestone];
}

/// Waits, without blocking the main queue, until the INVITE is bound to `uuid`.
- (BOOL)waitUntilBound:(NSUUID *)uuid {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        CallWaveCall *call = [self.client.registry callForUUID:uuid];
        if (call != nil && call.callId != CallWaveSIPCallIdInvalid) {
            return YES;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return NO;
}

- (void)spinFor:(NSTimeInterval)seconds {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (BOOL)waitForState:(CallWaveCallState)state ofUUID:(NSUUID *)uuid {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([self.client stateForCallWithUUID:uuid] == state) {
            return YES;
        }
        [self spinFor:0.005];
    }
    return NO;
}

#pragma mark - 200 OK within 50 ms of the binding

/// The host answers first — the lock-screen case, where the push beats the
/// INVITE — and `200 OK` follows the binding of the INVITE at once.
- (void)testAnAnswerGivenBeforeTheInviteGoesOutWhenTheInviteIsBound {
    if (![self startEngine]) return;
    NSUUID *uuid = [NSUUID UUID];
    NSString *callId = [self newCallId];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];

    XCTestExpectation *answered = [self expectationWithDescription:@"answered"];
    [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertNil(error);
        [answered fulfill];
    }];
    [self.intercom sendInviteWithCallId:callId];

    CallWaveLoopbackPacket *ringing =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:180]
                                      within:5];
    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok, @"200 OK never reached the wire");
    [self waitForExpectations:@[answered] timeout:5];

    uint64_t boundAt = [self timeOf:CallWaveAnswerMilestoneInviteBound forUUID:uuid];
    XCTAssertGreaterThan(boundAt, 0u);
    double latency = CallWaveMillisecondsBetween(boundAt, ok.receivedAt);
    XCTAssertLessThan(latency, CallWaveAnswerBudgetMilliseconds,
                      @"200 OK left %.1f ms after the binding", latency);
    XCTAssertNotNil(ringing);
    XCTAssertLessThanOrEqual(ringing.receivedAt, ok.receivedAt, @"180 must precede 200");
    XCTAssertTrue([ok.message containsString:callId]);

    XCTAssertNotNil([self.log messageContaining:@"answered before its INVITE arrived"]);
    NSString *marker = [NSString stringWithFormat:@"answer timeline %@: 200 OK sent +",
                                                  uuid.UUIDString];
    XCTAssertNotNil([self.log messageContaining:marker]);
}

/// The INVITE is already bound when the host answers: `200 OK` follows the
/// answer at once.
- (void)testAnAnswerGivenAfterTheInviteGoesOutAtOnce {
    if (![self startEngine]) return;
    NSUUID *uuid = [NSUUID UUID];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.intercom sendInviteWithCallId:[self newCallId]];
    XCTAssertTrue([self waitUntilBound:uuid]);

    XCTestExpectation *answered = [self expectationWithDescription:@"answered"];
    uint64_t acceptedAt = CallWaveMonotonicNanoseconds();
    [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertNil(error);
        [answered fulfill];
    }];
    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok);
    [self waitForExpectations:@[answered] timeout:5];

    // The binding came first, so the answer is the later of the two events
    // `200 OK` waits for.
    double latency = CallWaveMillisecondsBetween(acceptedAt, ok.receivedAt);
    XCTAssertLessThan(latency, CallWaveAnswerBudgetMilliseconds,
                      @"200 OK left %.1f ms after acceptCall", latency);
    XCTAssertNotNil([self.log messageContaining:@"acceptCall, INVITE received -"]);
}

#pragma mark - The same with the main thread blocked for a second

- (void)testAnAnswerGivenBeforeTheInviteDoesNotWaitForTheMainQueue {
    if (![self startEngine]) return;
    NSUUID *uuid = [NSUUID UUID];
    NSString *callId = [self newCallId];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];

    CallWaveLoopbackIntercom *intercom = self.intercom;
    CallWaveClient *client = self.client;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [client acceptCallWithUUID:uuid completion:nil];
        [intercom sendInviteWithCallId:callId];
    });
    [NSThread sleepForTimeInterval:1.0];   // the main thread, busy with launch
    uint64_t unblockedAt = CallWaveMonotonicNanoseconds();

    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok);
    XCTAssertLessThan(ok.receivedAt, unblockedAt, @"200 OK waited for the main queue");
    uint64_t boundAt = [self timeOf:CallWaveAnswerMilestoneInviteBound forUUID:uuid];
    XCTAssertGreaterThan(boundAt, 0u);
    XCTAssertLessThan(boundAt, unblockedAt, @"the binding waited for the main queue");
    double latency = CallWaveMillisecondsBetween(boundAt, ok.receivedAt);
    XCTAssertLessThan(latency, CallWaveAnswerBudgetMilliseconds,
                      @"200 OK left %.1f ms after the binding", latency);

    // The state the host sees does wait for the main queue, and says by how much.
    XCTAssertTrue([self waitForState:CallWaveCallStateConnecting ofUUID:uuid]);
    XCTAssertNotNil([self.log messageContaining:@"main queue picked up the INVITE after"]);
}

- (void)testAnAnswerGivenAfterTheInviteDoesNotWaitForTheMainQueue {
    if (![self startEngine]) return;
    NSUUID *uuid = [NSUUID UUID];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.intercom sendInviteWithCallId:[self newCallId]];
    XCTAssertTrue([self waitUntilBound:uuid]);

    __block uint64_t acceptedAt = 0;
    CallWaveClient *client = self.client;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        acceptedAt = CallWaveMonotonicNanoseconds();
        [client acceptCallWithUUID:uuid completion:nil];
    });
    [NSThread sleepForTimeInterval:1.0];
    uint64_t unblockedAt = CallWaveMonotonicNanoseconds();

    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok);
    XCTAssertGreaterThan(acceptedAt, 0u);
    XCTAssertLessThan(ok.receivedAt, unblockedAt, @"200 OK waited for the main queue");
    double latency = CallWaveMillisecondsBetween(acceptedAt, ok.receivedAt);
    XCTAssertLessThan(latency, CallWaveAnswerBudgetMilliseconds,
                      @"200 OK left %.1f ms after acceptCall", latency);
}

/// A host that still wants a pause gets it, timed on the SIP queue.
- (void)testASettleDelayIsKeptWithoutTheMainQueue {
    if (![self startEngine]) return;
    self.client.acceptDelay = 0.3;
    NSUUID *uuid = [NSUUID UUID];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.intercom sendInviteWithCallId:[self newCallId]];
    XCTAssertTrue([self waitUntilBound:uuid]);

    __block uint64_t acceptedAt = 0;
    CallWaveClient *client = self.client;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        acceptedAt = CallWaveMonotonicNanoseconds();
        [client acceptCallWithUUID:uuid completion:nil];
    });
    [NSThread sleepForTimeInterval:1.0];
    uint64_t unblockedAt = CallWaveMonotonicNanoseconds();

    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok);
    XCTAssertLessThan(ok.receivedAt, unblockedAt, @"the pause was timed on the main queue");
    XCTAssertGreaterThanOrEqual(CallWaveMillisecondsBetween(acceptedAt, ok.receivedAt), 295.0,
                                @"the settle delay was not honoured");
}

#pragma mark - What must not break

/// Ending the call while its answer waits for the INVITE: the answer fails at
/// once instead of at `answerTimeout`, and the late INVITE is still refused.
- (void)testEndingOrDecliningACallWhoseAnswerWaitsRefusesTheInvite {
    if (![self startEngine]) return;
    self.client.answerTimeout = 10;
    for (NSNumber *declining in @[@NO, @YES]) {
        NSUUID *uuid = [NSUUID UUID];
        NSString *callId = [self newCallId];
        [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];

        XCTestExpectation *failed = [self expectationWithDescription:@"answer failed"];
        [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
            XCTAssertEqual(error.code, CallWaveErrorNoActiveCall);
            [failed fulfill];
        }];
        XCTestExpectation *ended = [self expectationWithDescription:@"ended"];
        CallWaveCompletion done = ^(NSError *error) {
            XCTAssertNil(error);
            [ended fulfill];
        };
        if (declining.boolValue) {
            [self.client declineCallWithUUID:uuid completion:done];
        } else {
            [self.client endCallWithUUID:uuid completion:done];
        }
        // Well inside answerTimeout: the end of the call is what fails it.
        [self waitForExpectations:@[failed, ended] timeout:2];

        [self.intercom sendInviteWithCallId:callId];
        CallWaveLoopbackPacket *refused = [self.intercom waitForPacketMatching:^BOOL(NSString *m) {
            return [m hasPrefix:@"SIP/2.0 603 "] && [m containsString:callId];
        } within:5];
        XCTAssertNotNil(refused, @"the late INVITE must still be answered 603");
        [self spinFor:0.2];
        XCTAssertNil([self.intercom packetMatching:^BOOL(NSString *m) {
            return [m hasPrefix:@"SIP/2.0 200 "] && [m containsString:callId];
        }], @"a call the user ended must never be answered");
    }
}

/// The intercom hangs up during the settle delay: no `200 OK` after it.
- (void)testAHangupDuringTheSettleDelaySkipsTheAnswer {
    if (![self startEngine]) return;
    self.client.acceptDelay = 0.5;
    NSUUID *uuid = [NSUUID UUID];
    NSString *callId = [self newCallId];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.intercom sendInviteWithCallId:callId];
    XCTAssertTrue([self waitUntilBound:uuid]);

    XCTestExpectation *failed = [self expectationWithDescription:@"answer failed"];
    [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertEqual(error.code, CallWaveErrorNoActiveCall);
        [failed fulfill];
    }];
    [self spinFor:0.1];
    [self.intercom sendCancelWithCallId:callId];
    XCTAssertNotNil([self.intercom waitForPacketMatching:
                     [CallWaveLoopbackIntercom responseToInviteWithStatus:487] within:5]);
    [self waitForExpectations:@[failed] timeout:3];
    XCTAssertNil([self.intercom packetMatching:
                  [CallWaveLoopbackIntercom responseToInviteWithStatus:200]]);
}

/// The host ends the call during the settle delay: `603`, and no `200 OK`.
- (void)testEndingTheCallDuringTheSettleDelaySkipsTheAnswer {
    if (![self startEngine]) return;
    self.client.acceptDelay = 0.5;
    NSUUID *uuid = [NSUUID UUID];
    NSString *callId = [self newCallId];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.intercom sendInviteWithCallId:callId];
    XCTAssertTrue([self waitUntilBound:uuid]);

    XCTestExpectation *failed = [self expectationWithDescription:@"answer failed"];
    [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertEqual(error.code, CallWaveErrorNoActiveCall);
        [failed fulfill];
    }];
    [self.client endCallWithUUID:uuid completion:nil];
    XCTAssertNotNil([self.intercom waitForPacketMatching:
                     [CallWaveLoopbackIntercom responseToInviteWithStatus:603] within:5]);
    [self waitForExpectations:@[failed] timeout:3];
    XCTAssertNil([self.intercom packetMatching:
                  [CallWaveLoopbackIntercom responseToInviteWithStatus:200]]);
}

/// A push the backend retries after the call was answered must not report it
/// again: that re-published `incoming` over an established call and armed a
/// ring timeout that later hung it up.
- (void)testARetriedPushAfterTheAnswerLeavesTheCallAlone {
    if (![self startEngine]) return;
    self.client.incomingCallTimeout = 1.0;
    NSUUID *uuid = [NSUUID UUID];
    NSString *callId = [self newCallId];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];   // retried before the answer
    [self.client acceptCallWithUUID:uuid completion:nil];
    [self.intercom sendInviteWithCallId:callId];

    CallWaveLoopbackPacket *ok =
        [self.intercom waitForPacketMatching:[CallWaveLoopbackIntercom responseToInviteWithStatus:200]
                                      within:5];
    XCTAssertNotNil(ok);
    [self.intercom sendACKForResponse:ok.message callId:callId];
    XCTAssertTrue([self waitForState:CallWaveCallStateActive ofUUID:uuid]);

    NSMutableArray<NSNumber *> *states = [NSMutableArray array];
    id token = [self.client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeCallStateChanged && [event.callUUID isEqual:uuid]) {
            [states addObject:@(event.callState)];
        }
    }];
    [self.client prepareIncomingCallWithUUID:uuid caller:@"door"];   // retried after it
    XCTestExpectation *again = [self expectationWithDescription:@"second answer"];
    [self.client acceptCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertNil(error, @"answering an answered call is a no-op, not a failure");
        [again fulfill];
    }];
    [self waitForExpectations:@[again] timeout:2];
    [self spinFor:1.5];   // past the ring timeout a second report would arm

    [self.client removeEventObserver:token];
    XCTAssertEqual([self.client stateForCallWithUUID:uuid], CallWaveCallStateActive);
    XCTAssertFalse([states containsObject:@(CallWaveCallStateIncoming)]);
    XCTAssertFalse([states containsObject:@(CallWaveCallStateConnecting)],
                   @"a second answer must not move an active call back");
    XCTAssertNil([self.intercom packetMatching:[CallWaveLoopbackIntercom requestWithMethod:@"BYE"]],
                 @"the established call was hung up");
    XCTAssertEqual([self.log countOfMessagesContaining:@"200 OK sent for call"], 1u,
                   @"one call, one answer");
}

/// No INVITE at all: the answer still gives up after `answerTimeout`.
- (void)testAnAnswerWithoutAnInviteTimesOut {
    CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:nil
                                                                   options:CallWaveIntegrationOptionNone
                                                                  provider:nil
                                                       engineConfiguration:nil];
    NSUUID *uuid = [NSUUID UUID];
    [client prepareIncomingCallWithUUID:uuid caller:@"door"];

    XCTestExpectation *timedOut = [self expectationWithDescription:@"timed out"];
    uint64_t acceptedAt = CallWaveMonotonicNanoseconds();
    [client acceptCallWithUUID:uuid timeout:0.2 completion:^(NSError *error) {
        XCTAssertEqual(error.code, CallWaveErrorTimedOut);
        XCTAssertGreaterThanOrEqual(
            CallWaveMillisecondsBetween(acceptedAt, CallWaveMonotonicNanoseconds()), 195.0);
        [timedOut fulfill];
    }];
    [self waitForExpectations:@[timedOut] timeout:2];
    XCTAssertNotNil([self.log messageContaining:@"giving up"]);
}

@end
