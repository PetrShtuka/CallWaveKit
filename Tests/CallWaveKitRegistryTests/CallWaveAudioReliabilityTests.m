#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "CallWaveClient.h"
#import "CallWaveCallRegistry.h"
#import "CallWaveAudioRouteInternal.h"

// Private entry points are redeclared here so the tests can drive the audio
// coordinator paths without changing the public API. `registry`,
// `audioSessionActive` and `desiredSpeakerEnabled` back the assertions;
// declaring them in a category is enough because the getters already exist in
// the class extension.
@interface CallWaveClient (AudioReliabilityTests)
@property (nonatomic, strong) CallWaveCallRegistry *registry;
@property (nonatomic, assign) BOOL audioSessionActive;
@property (nonatomic, assign) BOOL desiredSpeakerEnabled;
- (void)audioSessionWasInterrupted:(NSNotification *)notification;
- (void)audioSessionRouteDidChange:(NSNotification *)notification;
- (void)audioMediaServicesWereReset:(NSNotification *)notification;
@end

@interface CallWaveAudioReliabilityTests : XCTestCase
@end

@implementation CallWaveAudioReliabilityTests

- (CallWaveClient *)makeClient {
    return [[CallWaveClient alloc] initWithConfiguration:nil
                                                 options:CallWaveIntegrationOptionNone
                                                provider:nil
                                     engineConfiguration:nil];
}

- (NSNotification *)interruptionNotificationOfType:(AVAudioSessionInterruptionType)type
                                           options:(AVAudioSessionInterruptionOptions)options {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[AVAudioSessionInterruptionTypeKey] = @(type);
    if (options != 0) {
        userInfo[AVAudioSessionInterruptionOptionKey] = @(options);
    }
    return [NSNotification notificationWithName:AVAudioSessionInterruptionNotification
                                         object:nil
                                       userInfo:userInfo];
}

- (void)testInterruptionBeganDropsTheSoundDeviceAndPublishes {
    CallWaveClient *client = [self makeClient];
    client.audioSessionActive = YES;
    XCTestExpectation *eventReceived = [self expectationWithDescription:@"began event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioSessionInterrupted) {
            XCTAssertTrue(event.isAudioSessionInterrupted);
            [eventReceived fulfill];
        }
    }];

    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeBegan options:0]];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertFalse(client.audioSessionActive);
}

- (void)testInterruptionEndedWithShouldResumeReactivatesTheSession {
    CallWaveClient *client = [self makeClient];
    // The resume guard requires a live call; register one straight into the
    // registry rather than simulating a whole push.
    [client.registry registerCallWithUUID:[NSUUID UUID]];

    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeBegan options:0]];
    XCTAssertFalse(client.audioSessionActive);

    XCTestExpectation *eventReceived = [self expectationWithDescription:@"ended event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioSessionInterrupted) {
            XCTAssertFalse(event.isAudioSessionInterrupted);
            [eventReceived fulfill];
        }
    }];

    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeEnded
                                     options:AVAudioSessionInterruptionOptionShouldResume]];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertTrue(client.audioSessionActive,
                  @"a resumable interruption with a live call must reactivate the session");
}

- (void)testInterruptionEndedWithoutShouldResumeStaysInactive {
    CallWaveClient *client = [self makeClient];
    [client.registry registerCallWithUUID:[NSUUID UUID]];

    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeBegan options:0]];

    XCTestExpectation *eventReceived = [self expectationWithDescription:@"ended event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioSessionInterrupted) {
            [eventReceived fulfill];
        }
    }];

    // A phone call that the user answered and ended elsewhere: iOS does not
    // offer ShouldResume, so the VoIP call must stay on its deactivated
    // session instead of stealing audio back.
    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeEnded options:0]];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertFalse(client.audioSessionActive);
}

- (void)testInterruptionEndedWithShouldResumeButNoCallsStaysInactive {
    CallWaveClient *client = [self makeClient];

    [client audioSessionWasInterrupted:
        [self interruptionNotificationOfType:AVAudioSessionInterruptionTypeEnded
                                     options:AVAudioSessionInterruptionOptionShouldResume]];

    XCTAssertFalse(client.audioSessionActive,
                   @"reactivating with no live call would grab audio for nothing");
}

- (void)testRouteChangePublishesTheCurrentRoute {
    CallWaveClient *client = [self makeClient];
    XCTestExpectation *eventReceived = [self expectationWithDescription:@"route event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioRouteChanged) {
            XCTAssertNotNil(event.audioRoute);
            [eventReceived fulfill];
        }
    }];
    NSNotification *notification = [NSNotification
        notificationWithName:AVAudioSessionRouteChangeNotification
        object:nil
        userInfo:@{AVAudioSessionRouteChangeReasonKey:
                       @(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}];

    [client audioSessionRouteDidChange:notification];

    [self waitForExpectations:@[eventReceived] timeout:1];
}

- (void)testSpeakerPreferenceSurvivesARouteLoss {
    CallWaveClient *client = [self makeClient];
    NSError *error = nil;
    if (![client setSpeakerEnabled:YES error:&error]) {
        // The simulator may refuse the override; the restore logic is what
        // matters, so drive the flag directly in that case.
        client.desiredSpeakerEnabled = YES;
    }
    XCTAssertTrue(client.desiredSpeakerEnabled);

    XCTestExpectation *eventReceived = [self expectationWithDescription:@"route event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioRouteChanged) {
            [eventReceived fulfill];
        }
    }];
    // A Bluetooth headset disappearing mid-call: the route changes away from
    // the speaker, and the coordinator must try to put it back.
    NSNotification *notification = [NSNotification
        notificationWithName:AVAudioSessionRouteChangeNotification
        object:nil
        userInfo:@{AVAudioSessionRouteChangeReasonKey:
                       @(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}];

    [client audioSessionRouteDidChange:notification];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertTrue(client.desiredSpeakerEnabled,
                  @"a route change must not clear the user's speaker preference");
    XCTAssertTrue(client.currentAudioRoute.isSpeakerActive,
                  @"the speaker route should have been restored after the loss");
}

- (void)testSpeakerPreferenceIsClearedOnlyByTheUser {
    CallWaveClient *client = [self makeClient];
    client.desiredSpeakerEnabled = YES;

    NSError *error = nil;
    [client setSpeakerEnabled:NO error:&error];

    XCTAssertFalse(client.desiredSpeakerEnabled);
}

- (void)testMediaServicesResetReconfiguresAndPublishes {
    CallWaveClient *client = [self makeClient];
    [client.registry registerCallWithUUID:[NSUUID UUID]];
    client.audioSessionActive = YES;
    XCTestExpectation *eventReceived = [self expectationWithDescription:@"route event"];
    // Reactivation and the reset handler each publish the route.
    eventReceived.expectedFulfillmentCount = 2;
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioRouteChanged) {
            [eventReceived fulfill];
        }
    }];
    NSNotification *notification = [NSNotification
        notificationWithName:AVAudioSessionMediaServicesWereResetNotification
        object:nil
        userInfo:nil];

    [client audioMediaServicesWereReset:notification];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertTrue(client.audioSessionActive,
                  @"with a live call the session must come back after a media reset");
}

- (void)testAudioRouteReportsBluetoothAndSpeakerIndependently {
    CallWaveAudioRoute *bluetoothOnly = [[CallWaveAudioRoute alloc]
        initWithInputPortTypes:@[AVAudioSessionPortBluetoothHFP]
        outputPortTypes:@[AVAudioSessionPortBluetoothHFP]];
    XCTAssertTrue(bluetoothOnly.isBluetoothActive);
    XCTAssertFalse(bluetoothOnly.isSpeakerActive);

    CallWaveAudioRoute *receiverOnly = [[CallWaveAudioRoute alloc]
        initWithInputPortTypes:@[AVAudioSessionPortBuiltInMic]
        outputPortTypes:@[AVAudioSessionPortBuiltInReceiver]];
    XCTAssertFalse(receiverOnly.isBluetoothActive);
    XCTAssertFalse(receiverOnly.isSpeakerActive);
}

@end
