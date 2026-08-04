#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <PushKit/PushKit.h>

#import "CallWaveClient.h"
#import "CallWaveAudioRouteInternal.h"

// Private notification entry points are declared here so the tests can drive
// the coordinator without changing the public API.
@interface CallWaveClient (ReliabilityTests)
- (void)audioSessionWasInterrupted:(NSNotification *)notification;
- (void)pushRegistry:(nullable PKPushRegistry *)registry
didInvalidatePushTokenForType:(PKPushType)type;
@end

@interface CallWaveTokenDelegate : NSObject <CallWaveClientDelegate>
@property (nonatomic, assign) NSUInteger invalidationCount;
@end

@implementation CallWaveTokenDelegate
- (void)callWaveClientDidInvalidateVoIPPushToken:(CallWaveClient *)client {
    self.invalidationCount++;
}
@end

@interface CallWaveClientReliabilityTests : XCTestCase
@end

@implementation CallWaveClientReliabilityTests

- (CallWaveClient *)makeClient {
    return [[CallWaveClient alloc] initWithConfiguration:nil
                                                 options:CallWaveIntegrationOptionNone
                                                provider:nil
                                     engineConfiguration:nil];
}

- (void)testVoIPTokenInvalidationReachesDelegateAndEventStream {
    CallWaveClient *client = [self makeClient];
    CallWaveTokenDelegate *delegate = [[CallWaveTokenDelegate alloc] init];
    client.delegate = delegate;
    XCTestExpectation *eventReceived = [self expectationWithDescription:@"token event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeVoIPPushTokenInvalidated) {
            [eventReceived fulfill];
        }
    }];

    [client pushRegistry:nil didInvalidatePushTokenForType:PKPushTypeVoIP];

    [self waitForExpectations:@[eventReceived] timeout:1];
    XCTAssertEqual(delegate.invalidationCount, (NSUInteger)1);
}

- (void)testAudioInterruptionPublishesItsState {
    CallWaveClient *client = [self makeClient];
    XCTestExpectation *eventReceived = [self expectationWithDescription:@"audio event"];
    [client addEventObserver:^(CallWaveEvent *event) {
        if (event.type == CallWaveEventTypeAudioSessionInterrupted) {
            XCTAssertTrue(event.isAudioSessionInterrupted);
            [eventReceived fulfill];
        }
    }];
    NSNotification *notification = [NSNotification
        notificationWithName:AVAudioSessionInterruptionNotification
        object:nil
        userInfo:@{AVAudioSessionInterruptionTypeKey:
                       @(AVAudioSessionInterruptionTypeBegan)}];

    [client audioSessionWasInterrupted:notification];

    [self waitForExpectations:@[eventReceived] timeout:1];
}

- (void)testAudioRouteUsesPortTypesWithoutDeviceNames {
    CallWaveAudioRoute *route = [[CallWaveAudioRoute alloc]
        initWithInputPortTypes:@[AVAudioSessionPortBluetoothHFP]
        outputPortTypes:@[AVAudioSessionPortBuiltInSpeaker]];

    XCTAssertTrue(route.isBluetoothActive);
    XCTAssertTrue(route.isSpeakerActive);
    XCTAssertEqualObjects(route.inputPortTypes, (@[AVAudioSessionPortBluetoothHFP]));
    XCTAssertEqualObjects(route.outputPortTypes, (@[AVAudioSessionPortBuiltInSpeaker]));
}

@end
