#import <XCTest/XCTest.h>

#import "CallWaveClient.h"
#import "CallWaveLogInternal.h"

// The decline path used to be entirely silent: no CWLog anywhere between
// -endCall and the SIP message, so a host looking at a PBX that kept ringing
// could not tell a final response that was lost in transit from one that was
// never generated. These tests only pin the weakest guarantee — that the path
// says something, whatever the outcome — because everything past "handed to the
// transport" needs a peer, and that lives in FIELD-TESTING.md scenario 4.

@interface CallWaveTeardownProbe : NSObject <CallWaveLogger>
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@end

@implementation CallWaveTeardownProbe

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

@interface CallWaveClient (TeardownLoggingTests)
- (BOOL)endSIPCall:(int)callId
     declineStatus:(int)declineStatus
            reason:(NSString *)reason;
@end

@interface CallWaveTeardownLoggingTests : XCTestCase
@property (nonatomic, strong) CallWaveTeardownProbe *probe;
@property (nonatomic, assign) CallWaveLogLevel previousLevel;
@end

@implementation CallWaveTeardownLoggingTests

- (void)setUp {
    [super setUp];
    self.probe = [[CallWaveTeardownProbe alloc] init];
    self.previousLevel = CallWaveLog.level;
    CallWaveLog.level = CallWaveLogLevelDebug;
    CallWaveLog.logger = self.probe;
}

- (void)tearDown {
    CallWaveLog.logger = nil;
    CallWaveLog.level = self.previousLevel;
    self.probe = nil;
    [super tearDown];
}

- (CallWaveClient *)makeClient {
    return [[CallWaveClient alloc] initWithConfiguration:nil
                                                 options:CallWaveIntegrationOptionNone
                                                provider:nil
                                     engineConfiguration:nil];
}

/// The engine is not running here, which is the most silent case there is: no
/// PJSUA, no call, nothing to send. It still has to leave a trace, because from
/// the host's side this is indistinguishable from a decline that worked.
- (void)testTeardownOnAStoppedEngineIsStillLogged {
    CallWaveClient *client = [self makeClient];

    XCTAssertFalse([client endSIPCall:7 declineStatus:603 reason:@"unit test"]);

    XCTAssertTrue([self.probe sawMessageContaining:@"no SIP teardown for call 7"]);
    XCTAssertTrue([self.probe sawMessageContaining:@"unit test"],
                  @"the reason a call was torn down has to survive into the log");
}

/// -endCall on a call whose INVITE never arrived resolves to the deferred
/// rejection rather than to a SIP message, and that decision is the one a host
/// most often mistakes for a sent 603.
- (void)testRejectionBeforeTheInviteSaysSoInTheLog {
    CallWaveClient *client = [self makeClient];
    NSUUID *uuid = [NSUUID UUID];
    [client prepareIncomingCallWithUUID:uuid caller:@"door"];

    XCTestExpectation *ended = [self expectationWithDescription:@"ended"];
    [client endCallWithUUID:uuid completion:^(NSError *error) {
        XCTAssertNil(error);
        [ended fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];

    XCTAssertTrue([self.probe sawMessageContaining:@"before its INVITE arrived"]);
}

@end
