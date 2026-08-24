#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

#import "CallWaveClient.h"
#import "CallWaveIncomingCallDescriptor.h"
#import "CallWaveAudioSessionCoordinator.h"
#import "CallWaveCallStateMachine.h"
#import "CallWaveCallRegistry.h"

// The published properties are written on the main queue and read from the SIP
// queue, from PJSIP's callback threads and from the host's own threads. These
// tests hammer both sides at once: unsynchronized object-typed accessors
// over-release rather than merely returning a stale value, so a regression here
// crashes long before it corrupts anything subtler. Run the suite under the
// thread sanitizer to see the race itself rather than only its consequences.

// -displayNameForCaller: is internal; the tests reach it the same way the
// PJSIP callback threads do.
@interface CallWaveClient (PublishedStateConcurrencyTests)
- (NSString *)displayNameForCaller:(nullable NSString *)caller;
@end

static const NSUInteger CallWaveConcurrencyIterations = 50000;

@interface CallWavePublishedStateConcurrencyTests : XCTestCase
@end

@implementation CallWavePublishedStateConcurrencyTests

- (CallWaveClient *)makeClient {
    return [[CallWaveClient alloc] initWithConfiguration:nil
                                                 options:CallWaveIntegrationOptionNone
                                                provider:nil
                                     engineConfiguration:nil];
}

/// Runs `writer` and `reader` against each other for real: both threads spin on
/// a start gate first, so the two loops overlap instead of finishing one after
/// the other. Without the gate the loops are short enough to serialize by
/// accident, and then neither the sanitizer nor an over-release ever sees the
/// window they are meant to expose.
- (void)hammerWithWriter:(void (^)(NSUInteger))writer
                  reader:(void (^)(NSUInteger))reader {
    [self hammerWithIterations:CallWaveConcurrencyIterations writer:writer reader:reader];
}

- (void)hammerWithIterations:(NSUInteger)iterations
                      writer:(void (^)(NSUInteger))writer
                      reader:(void (^)(NSUInteger))reader {
    XCTestExpectation *done = [self expectationWithDescription:@"hammer"];
    done.expectedFulfillmentCount = 2;

    _Atomic(int) *gate = calloc(1, sizeof(_Atomic(int)));
    XCTAssertTrue(gate != NULL);
    dispatch_queue_t concurrent =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    void (^run)(void (^)(NSUInteger)) = ^(void (^body)(NSUInteger)) {
        dispatch_async(concurrent, ^{
            atomic_fetch_add(gate, 1);
            while (atomic_load(gate) < 2) {
                // Both sides are in flight before either touches the property.
            }
            for (NSUInteger i = 0; i < iterations; i++) {
                @autoreleasepool { body(i); }
            }
            [done fulfill];
        });
    };
    run(writer);
    run(reader);

    [self waitForExpectationsWithTimeout:60 handler:nil];
    free(gate);
}

- (void)testDefaultCallerNameSurvivesConcurrentReadsAndWrites {
    CallWaveClient *client = [self makeClient];

    [self hammerWithWriter:^(NSUInteger i) {
        client.defaultCallerName = [NSString stringWithFormat:@"Door %lu", (unsigned long)i];
    } reader:^(NSUInteger i) {
        // -displayNameForCaller: is what the PJSIP callback thread actually
        // reaches this property through.
        XCTAssertGreaterThan([client displayNameForCaller:@""].length, 0u);
    }];

    XCTAssertGreaterThan(client.defaultCallerName.length, 0u);
}

- (void)testPushPayloadParserSurvivesConcurrentReadsAndWrites {
    CallWaveClient *client = [self makeClient];
    NSUUID *uuid = [NSUUID UUID];

    [self hammerWithWriter:^(NSUInteger i) {
        client.pushPayloadParser = (i % 2 == 0) ? nil : ^CallWaveIncomingCallDescriptor *(NSDictionary *payload) {
            return [CallWaveIncomingCallDescriptor descriptorWithUUID:uuid caller:@"probe"];
        };
    } reader:^(NSUInteger i) {
        CallWavePushPayloadParser parser = client.pushPayloadParser;
        if (parser != nil) {
            XCTAssertNotNil(parser(@{}));
        }
    }];
}

- (void)testCurrentCallProjectionSurvivesConcurrentReadsAndWrites {
    CallWaveClient *client = [self makeClient];

    [self hammerWithWriter:^(NSUInteger i) {
        client.defaultCallerName = [NSString stringWithFormat:@"%lu", (unsigned long)i];
    } reader:^(NSUInteger i) {
        // The argument-less call actions read this projection from whatever
        // thread the host calls them on.
        (void)client.currentCallUUID;
        (void)client.currentCaller;
        (void)client.callState;
        (void)client.isRunning;
        (void)client.registrationState;
        (void)client.registrationError;
    }];
}

/// The call projection lives in CallWaveCallStateMachine, but it is read
/// through the client's pass-throughs from whatever thread the host calls a
/// public method on — -resolveCallForUUID: backs every argument-less call
/// action. This drives the machine's writers directly against those reads.
- (void)testCallStateMachineProjectionSurvivesConcurrentReadsAndWrites {
    CallWaveCallRegistry *registry = [[CallWaveCallRegistry alloc] init];
    CallWaveCallStateMachine *machine =
        [[CallWaveCallStateMachine alloc] initWithRegistry:registry];

    NSMutableArray<NSUUID *> *uuids = [NSMutableArray array];
    for (NSUInteger i = 0; i < 8; i++) {
        NSUUID *uuid = [NSUUID UUID];
        CallWaveCall *call = [registry registerCallWithUUID:uuid];
        call.displayName = [NSString stringWithFormat:@"Door %lu", (unsigned long)i];
        [uuids addObject:uuid];
    }

    [self hammerWithWriter:^(NSUInteger i) {
        NSUUID *uuid = uuids[i % uuids.count];
        if (i % 3 == 0) {
            [machine publishState:CallWaveCallStateActive forUUID:uuid];
        } else if (i % 3 == 1) {
            [machine adoptCurrentCall:[registry callForUUID:uuid]];
        } else {
            [machine detachIfCurrentUUID:uuid];
        }
    } reader:^(NSUInteger i) {
        (void)machine.currentCallUUID;
        (void)machine.currentCaller;
        (void)machine.state;
        (void)machine.microphoneMuted;
        (void)[machine resolveCallForUUID:nil];
    }];
}

- (void)testAudioRouteSurvivesConcurrentPublishAndRead {
    CallWaveAudioSessionCoordinator *coordinator =
        [[CallWaveAudioSessionCoordinator alloc] init];

    // Every notification queues a publish onto the main queue, so this one runs
    // far fewer rounds than the plain property tests.
    [self hammerWithIterations:2000 writer:^(NSUInteger i) {
        // AVAudioSession delivers route changes on its own thread; this is the
        // same entry point it calls.
        [coordinator handleRouteChangeNotification:
            [NSNotification notificationWithName:AVAudioSessionRouteChangeNotification
                                          object:nil]];
    } reader:^(NSUInteger i) {
        XCTAssertNotNil(coordinator.currentAudioRoute);
        coordinator.audioSessionActive = (i % 2 == 0);
        (void)coordinator.desiredSpeakerEnabled;
    }];

    XCTAssertNotNil(coordinator.currentAudioRoute);
}

@end
