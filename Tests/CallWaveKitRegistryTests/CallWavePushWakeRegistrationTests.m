#import <XCTest/XCTest.h>

#import "CallWaveClient.h"
#import "CallWaveLogInternal.h"

#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

// A push for a host that only learns its credentials from that push used to
// run the full -startWithError: path, which has no configuration to register
// and therefore failed with CallWaveErrorNotConfigured on every single call.
// The call itself survived — the host's -loginWithConfiguration: landed a
// moment later — but every call logged an error for a state the library
// documents as supported.

@interface CallWaveClient (PushWakeTests)
- (void)performSIPSync:(NS_NOESCAPE dispatch_block_t)block;
- (void)wakeRegistration;
@end

@interface CallWavePushWakeProbe : NSObject <CallWaveLogger>
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@end

@implementation CallWavePushWakeProbe

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

// Counts the nudges a single push produces.
@interface CallWaveWakeCountingClient : CallWaveClient
@property (nonatomic, assign) NSUInteger wakeCount;
@end

@implementation CallWaveWakeCountingClient
- (void)wakeRegistration {
    self.wakeCount += 1;
    [super wakeRegistration];
}
@end

@interface CallWavePushWakeRegistrationTests : XCTestCase
@property (nonatomic, strong) CallWavePushWakeProbe *probe;
@property (nonatomic, assign) CallWaveLogLevel previousLevel;
@end

@implementation CallWavePushWakeRegistrationTests

- (void)setUp {
    [super setUp];
    self.probe = [[CallWavePushWakeProbe alloc] init];
    self.previousLevel = CallWaveLog.level;
    CallWaveLog.level = CallWaveLogLevelInfo;
    CallWaveLog.logger = self.probe;
}

- (void)tearDown {
    CallWaveLog.logger = nil;
    CallWaveLog.level = self.previousLevel;
    self.probe = nil;
    [super tearDown];
}

- (CallWaveEngineConfiguration *)engine {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.handlesNetworkChanges = NO;
    engine.logLevel = CallWaveLogLevelInfo;
    return engine;
}

- (void)testPushBeforeLoginDoesNotReportMissingConfiguration {
    CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:nil
                                                                  options:CallWaveIntegrationOptionNone
                                                                 provider:nil
                                                      engineConfiguration:[self engine]];

    [client prepareIncomingCallWithUUID:[NSUUID UUID] caller:@"1001"];
    // The wake is queued on the SIP queue before this returns, so a synchronous
    // turn behind it is enough to observe whatever it logged.
    [client performSIPSync:^{}];

    XCTAssertFalse([self.probe sawMessageContaining:@"No configuration"]);
    XCTAssertTrue([self.probe sawMessageContaining:@"no SIP account yet"]);
    XCTAssertFalse(client.isRunning);
}

- (void)testHostOwnedPushNudgesRegistrationOnce {
    CallWaveWakeCountingClient *client =
        [[CallWaveWakeCountingClient alloc] initWithConfiguration:nil
                                                          options:CallWaveIntegrationOptionNone
                                                         provider:nil
                                              engineConfiguration:[self engine]];

    XCTestExpectation *handled = [self expectationWithDescription:@"push handled"];
    [client handleVoIPPushPayload:@{@"uuid": [NSUUID UUID].UUIDString, @"caller_id": @"1001"}
                       completion:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [handled fulfill]; });
    [self waitForExpectations:@[handled] timeout:2];

    XCTAssertEqual(client.wakeCount, 1u);
}

- (CallWaveConfiguration *)configuration {
    return [[CallWaveConfiguration alloc] initWithHost:@"127.0.0.1"
                                                  port:5099
                                             transport:CallWaveTransportUDP
                                              username:@"test"
                                              password:@"test"
                                includesCallsInRecents:NO];
}

- (void)testPushWithCredentialsStartsTheStack {
    CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:[self configuration]
                                                                  options:CallWaveIntegrationOptionNone
                                                                 provider:nil
                                                      engineConfiguration:[self engine]];

    [client prepareIncomingCallWithUUID:[NSUUID UUID] caller:@"1001"];
    [client performSIPSync:^{}];

    XCTAssertTrue(client.isRunning);
    [client stop];
}

- (void)testEngineStartsWhenSomethingElseAlreadyInitializedPJLIB {
    // A second PJSIP consumer in the process — the host itself, or another
    // library — leaves PJLIB initialized. pjsua_create() then no longer
    // registers the thread it runs on, which for a push-driven start is a
    // transient sipQueue worker: every PJLIB call on it used to abort.
    XCTAssertEqual(pj_init(), PJ_SUCCESS);

    CallWaveClient *client = [[CallWaveClient alloc] initWithConfiguration:[self configuration]
                                                                  options:CallWaveIntegrationOptionNone
                                                                 provider:nil
                                                      engineConfiguration:[self engine]];

    [client prepareIncomingCallWithUUID:[NSUUID UUID] caller:@"1001"];
    [client performSIPSync:^{}];

    XCTAssertTrue(client.isRunning);
    [client stop];
    // The client's own pj_init()/pj_shutdown() pair leaves this one standing.
    pj_shutdown();
}

@end
