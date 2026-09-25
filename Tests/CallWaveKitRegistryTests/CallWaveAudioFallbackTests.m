#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "CallWaveAudioSessionCoordinator.h"
#import "CallWaveAnswerTimeline.h"
#import "CallWaveLogging.h"

// The fallback covers CallKit not delivering `didActivate`, which it most
// often fails to do on a cold start from the lock screen — exactly when the
// host's main queue is busiest. These drive the coordinator with a stand-in for
// the session, since a test process has no CallKit to activate a real one.

@interface CallWaveFallbackTestCoordinator : CallWaveAudioSessionCoordinator
@property (atomic, assign) NSUInteger activationCount;
@property (atomic, assign) NSUInteger speakerOverrideCount;
@end

@implementation CallWaveFallbackTestCoordinator
- (BOOL)setSessionActiveWithError:(NSError **)error {
    self.activationCount += 1;
    return YES;
}
- (BOOL)overrideOutputToSpeakerOnSession:(AVAudioSession *)session {
    self.speakerOverrideCount += 1;
    return YES;
}
@end

@interface CallWaveFallbackProbe : NSObject <CallWaveAudioSessionCoordinatorDelegate>
@property (atomic, assign) BOOL hasCalls;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *activations;
@property (atomic, assign) BOOL fallbackRanOnMainThread;
@property (atomic, assign) uint64_t fallbackAt;
@property (nonatomic, strong, nullable) XCTestExpectation *fallbackFired;
@end

@implementation CallWaveFallbackProbe

- (instancetype)init {
    self = [super init];
    if (self) {
        _activations = [NSMutableArray array];
        _hasCalls = YES;
    }
    return self;
}

- (BOOL)audioCoordinatorHasTrackedCalls:(CallWaveAudioSessionCoordinator *)coordinator {
    return self.hasCalls;
}

- (void)audioCoordinator:(CallWaveAudioSessionCoordinator *)coordinator
    requestsSoundDeviceStartAfter:(CallWaveAudioActivation)activation {
    @synchronized (self) {
        [self.activations addObject:@(activation)];
    }
    if (activation == CallWaveAudioActivationFallback) {
        self.fallbackRanOnMainThread = NSThread.isMainThread;
        self.fallbackAt = CallWaveMonotonicNanoseconds();
        [self.fallbackFired fulfill];
    }
}

- (void)audioCoordinatorRequestsSoundDeviceStop:(CallWaveAudioSessionCoordinator *)coordinator {
}

- (void)audioCoordinator:(CallWaveAudioSessionCoordinator *)coordinator
     didUpdateAudioRoute:(CallWaveAudioRoute *)route {
}

- (void)audioCoordinator:(CallWaveAudioSessionCoordinator *)coordinator
       interruptionBegan:(BOOL)began {
}

- (NSArray<NSNumber *> *)recordedActivations {
    @synchronized (self) {
        return [self.activations copy];
    }
}

@end

@interface CallWaveFallbackLog : NSObject <CallWaveLogger>
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@end

@implementation CallWaveFallbackLog
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
- (BOOL)sawMessageContaining:(NSString *)needle {
    @synchronized (self) {
        for (NSString *message in self.messages) {
            if ([message containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}
@end

@interface CallWaveAudioFallbackTests : XCTestCase
@property (nonatomic, strong) CallWaveFallbackTestCoordinator *audio;
@property (nonatomic, strong) CallWaveFallbackProbe *probe;
@property (nonatomic, strong) CallWaveFallbackLog *log;
@property (nonatomic, assign) CallWaveLogLevel previousLevel;
@end

@implementation CallWaveAudioFallbackTests

- (void)setUp {
    [super setUp];
    self.audio = [CallWaveFallbackTestCoordinator new];
    self.probe = [CallWaveFallbackProbe new];
    self.audio.delegate = self.probe;
    self.log = [CallWaveFallbackLog new];
    self.previousLevel = CallWaveLog.level;
    CallWaveLog.level = CallWaveLogLevelInfo;
    CallWaveLog.logger = self.log;
}

- (void)tearDown {
    CallWaveLog.logger = nil;
    CallWaveLog.level = self.previousLevel;
    [super tearDown];
}

- (void)testTheDefaultDelayIsTheOneDocumented {
    XCTAssertEqualWithAccuracy([CallWaveAudioSessionCoordinator new].activationFallbackDelay,
                               1.5, 0.0001);
}

- (void)testTheFallbackActivatesTheSessionAfterTheConfiguredDelay {
    self.audio.activationFallbackDelay = 0.2;
    self.probe.fallbackFired = [self expectationWithDescription:@"fallback"];
    uint64_t scheduledAt = CallWaveMonotonicNanoseconds();

    [self.audio scheduleAudioSessionFallback];

    [self waitForExpectations:@[self.probe.fallbackFired] timeout:2];
    XCTAssertGreaterThanOrEqual(CallWaveMillisecondsBetween(scheduledAt, self.probe.fallbackAt),
                                195.0, @"the fallback must not fire before its delay");
    XCTAssertTrue(self.audio.audioSessionActive);
    XCTAssertEqual(self.audio.activationCount, 1u);
    XCTAssertEqualObjects(self.probe.recordedActivations, @[@(CallWaveAudioActivationFallback)]);
}

/// The whole point of moving the timer: on a cold start the main queue is
/// still busy with launch, and audio must not wait for it.
- (void)testTheFallbackFiresWhileTheMainQueueIsBlocked {
    self.audio.activationFallbackDelay = 0.1;
    self.probe.fallbackFired = [self expectationWithDescription:@"fallback"];

    [self.audio scheduleAudioSessionFallback];
    uint64_t blockedAt = CallWaveMonotonicNanoseconds();
    [NSThread sleepForTimeInterval:1.0];   // the main thread, blocked
    uint64_t unblockedAt = CallWaveMonotonicNanoseconds();

    [self waitForExpectations:@[self.probe.fallbackFired] timeout:2];
    XCTAssertFalse(self.probe.fallbackRanOnMainThread);
    XCTAssertLessThan(self.probe.fallbackAt, unblockedAt,
                      @"the fallback waited for the main queue");
    XCTAssertLessThan(CallWaveMillisecondsBetween(blockedAt, self.probe.fallbackAt), 500.0);
}

- (void)testTheFallbackStaysQuietWhenCallKitActivatedFirst {
    self.audio.activationFallbackDelay = 0.05;
    [self.audio scheduleAudioSessionFallback];
    [self.audio audioSessionDidActivate:AVAudioSession.sharedInstance];

    [NSThread sleepForTimeInterval:0.3];

    XCTAssertEqual(self.audio.activationCount, 0u, @"CallKit's activation is the one that counts");
    XCTAssertEqualObjects(self.probe.recordedActivations, @[@(CallWaveAudioActivationCallKit)]);
}

- (void)testTheFallbackStaysQuietWithoutACall {
    self.probe.hasCalls = NO;
    self.audio.activationFallbackDelay = 0.05;
    [self.audio scheduleAudioSessionFallback];

    [NSThread sleepForTimeInterval:0.3];

    XCTAssertFalse(self.audio.audioSessionActive);
    XCTAssertEqual(self.probe.recordedActivations.count, 0u);
}

/// CallKit's `didActivate` arriving after the manual activation is the case a
/// shorter delay makes more common. It must be a second, harmless activation:
/// the sound device is asked for again (PJSUA keeps it open when nothing
/// changed), and a speaker route the host chose is applied again rather than
/// lost.
- (void)testALateCallKitActivationAfterTheFallbackKeepsTheHostsSpeaker {
    self.audio.desiredSpeakerEnabled = YES;
    self.audio.activationFallbackDelay = 0.05;
    self.probe.fallbackFired = [self expectationWithDescription:@"fallback"];
    [self.audio scheduleAudioSessionFallback];
    [self waitForExpectations:@[self.probe.fallbackFired] timeout:2];
    XCTAssertEqual(self.audio.speakerOverrideCount, 1u);

    [self.audio audioSessionDidActivate:AVAudioSession.sharedInstance];

    XCTAssertTrue(self.audio.audioSessionActive);
    XCTAssertTrue(self.audio.desiredSpeakerEnabled, @"the host's speaker choice survives");
    XCTAssertEqual(self.audio.speakerOverrideCount, 2u,
                   @"CallKit's activation may reset the route; the speaker is applied again");
    NSArray *expected = @[@(CallWaveAudioActivationFallback), @(CallWaveAudioActivationCallKit)];
    XCTAssertEqualObjects(self.probe.recordedActivations, expected);
    // The measurement a new default is chosen from: how late CallKit was.
    XCTAssertTrue([self.log sawMessageContaining:@"CallKit activated the session"]);
    XCTAssertTrue([self.log sawMessageContaining:@"ms after the fallback did"]);
}

- (void)testALateCallKitActivationLeavesTheReceiverAlone {
    self.audio.desiredSpeakerEnabled = NO;
    self.audio.activationFallbackDelay = 0.05;
    self.probe.fallbackFired = [self expectationWithDescription:@"fallback"];
    [self.audio scheduleAudioSessionFallback];
    [self waitForExpectations:@[self.probe.fallbackFired] timeout:2];

    [self.audio audioSessionDidActivate:AVAudioSession.sharedInstance];

    XCTAssertEqual(self.audio.speakerOverrideCount, 0u);
    XCTAssertFalse(self.audio.desiredSpeakerEnabled);
}

/// A deactivation between the two resets the pairing, so a later call's
/// activation is not reported as a late answer to this one's fallback.
- (void)testDeactivationEndsTheFallbackPairing {
    self.audio.activationFallbackDelay = 0.05;
    self.probe.fallbackFired = [self expectationWithDescription:@"fallback"];
    [self.audio scheduleAudioSessionFallback];
    [self waitForExpectations:@[self.probe.fallbackFired] timeout:2];

    [self.audio audioSessionDidDeactivate:AVAudioSession.sharedInstance];
    XCTAssertFalse(self.audio.audioSessionActive);

    [self.audio audioSessionDidActivate:AVAudioSession.sharedInstance];
    XCTAssertTrue(self.audio.audioSessionActive);
    XCTAssertFalse([self.log sawMessageContaining:@"after the fallback did"]);
}

@end
