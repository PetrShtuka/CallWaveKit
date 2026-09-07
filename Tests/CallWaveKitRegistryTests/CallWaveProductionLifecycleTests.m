#import <XCTest/XCTest.h>
#import "CallWaveClient.h"
#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

@interface CallWaveClient (ProductionTests)
- (void)performSIPSync:(NS_NOESCAPE dispatch_block_t)block;
- (BOOL)claimRuntimeWithError:(NSError **)error;
- (void)setupCallKit;
- (void)setProvider:(CXProvider *)provider;
@end

// Forces the interleaving that used to happen between validation and use.
@interface CallWaveStopBeforeOperationClient : CallWaveClient
@property BOOL stopBeforeNextOperation;
@end
@implementation CallWaveStopBeforeOperationClient
- (void)performSIPSync:(NS_NOESCAPE dispatch_block_t)block {
    if (self.stopBeforeNextOperation) {
        self.stopBeforeNextOperation = NO;
        [self stop];
    }
    [super performSIPSync:block];
}
@end

// A provider-shaped double avoids invoking the OS call UI in unit tests.
@interface CallWavePushReportProbe : NSObject
@property NSMutableArray<NSUUID *> *reports;
@property NSMutableArray<NSUUID *> *ended;
@property (copy) void (^pendingCompletion)(NSError *);
@end
@implementation CallWavePushReportProbe
- (instancetype)init {
    if ((self = [super init])) { _reports = [NSMutableArray array]; _ended = [NSMutableArray array]; }
    return self;
}
- (void)reportNewIncomingCallWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update
                         completion:(void (^)(NSError *))completion {
    [self.reports addObject:uuid];
    self.pendingCompletion = completion;
}
- (void)reportCallWithUUID:(NSUUID *)uuid endedAtDate:(NSDate *)date reason:(CXCallEndedReason)reason {
    [self.ended addObject:uuid];
}
@end
@interface CallWaveManagedPushTestClient : CallWaveClient
@end
@implementation CallWaveManagedPushTestClient
- (void)setupCallKit {
    if (self.provider == nil) [self setProvider:(CXProvider *)[CallWavePushReportProbe new]];
}
@end

@interface CallWaveProductionLifecycleTests : XCTestCase
@end
@implementation CallWaveProductionLifecycleTests
- (CallWaveEngineConfiguration *)engine {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.handlesNetworkChanges = NO;
    return engine;
}
- (void)testDroppingRunningClientDestroysNativeRuntime {
    __weak CallWaveClient *weakClient;
    @autoreleasepool {
        CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:nil options:0
            provider:nil engineConfiguration:[self engine]];
        XCTAssertTrue([client startEngineWithError:NULL]);
        XCTAssertEqual(pjsua_get_state(), PJSUA_STATE_RUNNING);
        weakClient = client;
    }
    XCTAssertNil(weakClient);
    XCTAssertEqual(pjsua_get_state(), PJSUA_STATE_NULL);
}
- (void)testDroppingInitializationOwnerReleasesClaim {
    @autoreleasepool {
        CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:nil options:0
            provider:nil engineConfiguration:[self engine]];
        XCTAssertTrue([client claimRuntimeWithError:NULL]);
    }
    CallWaveClient *next = [[CallWaveClient alloc] initWithConfiguration:nil options:0
        provider:nil engineConfiguration:[self engine]];
    XCTAssertTrue([next startEngineWithError:NULL]);
    [next stop];
}
- (void)testRegistrationOperationsRejectStopBetweenEntryAndQueueTurn {
    for (NSString *operation in @[@"refresh", @"unregister", @"logout", @"registered", @"update"]) {
        CallWaveConfiguration *config = [[CallWaveConfiguration alloc] initWithHost:@"127.0.0.1"
            port:5099 transport:CallWaveTransportUDP username:@"test" password:@"test"
            includesCallsInRecents:NO];
        CallWaveStopBeforeOperationClient *client = [[CallWaveStopBeforeOperationClient alloc]
            initWithConfiguration:config options:0 provider:nil engineConfiguration:[self engine]];
        XCTAssertTrue([client startWithError:NULL]);
        client.stopBeforeNextOperation = YES;
        NSError *error = nil;
        BOOL result;
        if ([operation isEqual:@"refresh"]) result = [client refreshRegistrationWithError:&error];
        else if ([operation isEqual:@"unregister"]) result = [client unregisterWithError:&error];
        else if ([operation isEqual:@"logout"]) result = [client logoutWithError:&error];
        else if ([operation isEqual:@"update"]) result = [client updateConfiguration:config error:&error];
        else result = client.isRegistered;
        XCTAssertFalse(result, @"%@", operation);
        if (![operation isEqual:@"registered"]) XCTAssertEqual(error.code, CallWaveErrorEngineNotRunning);
        XCTAssertFalse(client.isRunning);
        XCTAssertEqual(client.registrationState, CallWaveRegistrationStateStopped);
        [client stop];
    }
}
- (void)testManagedCancellationAndLateAnnouncementReportBeforeCompletion {
    CallWaveManagedPushTestClient *client = [[CallWaveManagedPushTestClient alloc]
        initWithConfiguration:nil options:CallWaveIntegrationOptionManagesCallKit
        provider:nil engineConfiguration:[self engine]];
    CallWavePushReportProbe *probe = (id)client.provider;
    NSUUID *uuid = [NSUUID UUID];
    for (NSString *type in @[@"cancel", @"incoming"]) {
        __block BOOL completed = NO;
        XCTestExpectation *reported = [self expectationWithDescription:@"report submitted"];
        [client handleVoIPPushPayload:@{@"uuid": uuid.UUIDString, @"type": type}
            completion:^{ completed = YES; }];
        dispatch_async(dispatch_get_main_queue(), ^{ [reported fulfill]; });
        [self waitForExpectations:@[reported] timeout:2];
        XCTAssertEqualObjects(probe.reports.lastObject, uuid);
        XCTAssertFalse(completed);
        void (^callback)(NSError *) = probe.pendingCompletion;
        probe.pendingCompletion = nil;
        XCTAssertNotNil(callback);
        if (callback) callback(nil);
        XCTestExpectation *drained = [self expectationWithDescription:@"completion"];
        dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
        [self waitForExpectations:@[drained] timeout:2];
        XCTAssertTrue(completed);
        XCTAssertTrue([probe.ended containsObject:uuid]);
    }
    XCTAssertEqual(probe.reports.count, 2u);
}
@end
