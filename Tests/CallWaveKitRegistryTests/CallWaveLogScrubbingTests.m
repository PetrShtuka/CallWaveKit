#import <XCTest/XCTest.h>

#import "CallWaveLogInternal.h"

@interface CallWaveLogScrubbingTests : XCTestCase
@property (nonatomic, assign) BOOL previousRedaction;
@end

@implementation CallWaveLogScrubbingTests

- (void)setUp {
    [super setUp];
    self.previousRedaction = CallWaveLog.isRedactingIdentifiers;
    CallWaveLog.redactsIdentifiers = YES;
}

- (void)tearDown {
    CallWaveLog.redactsIdentifiers = self.previousRedaction;
    [super tearDown];
}

- (void)testAuthorizationValueIsScrubbedButTheHeaderNameStays {
    NSString *trace = @"REGISTER sip:pbx.example SIP/2.0\r\n"
                      @"Via: SIP/2.0/UDP 10.0.0.2:5060\r\n"
                      @"Authorization: Digest username=\"100\", "
                          @"response=\"1f4a9c2bdeadbeef\", nonce=\"abc\"\r\n"
                      @"Content-Length: 0";

    NSString *scrubbed = [CallWaveLog scrubAuthorizationInMessage:trace];

    XCTAssertFalse([scrubbed containsString:@"1f4a9c2bdeadbeef"]);
    XCTAssertFalse([scrubbed containsString:@"response="]);
    XCTAssertTrue([scrubbed containsString:@"Authorization: <redacted>"]);
    XCTAssertTrue([scrubbed containsString:@"Via: SIP/2.0/UDP 10.0.0.2:5060"]);
    XCTAssertTrue([scrubbed containsString:@"Content-Length: 0"]);
}

- (void)testProxyAuthorizationIsScrubbedToo {
    NSString *trace = @"INVITE sip:100@pbx.example SIP/2.0\n"
                      @"Proxy-Authorization: Digest response=\"cafe\"\n"
                      @"Max-Forwards: 70\n";

    NSString *scrubbed = [CallWaveLog scrubAuthorizationInMessage:trace];

    XCTAssertFalse([scrubbed containsString:@"cafe"]);
    XCTAssertTrue([scrubbed containsString:@"Proxy-Authorization: <redacted>"]);
    XCTAssertTrue([scrubbed containsString:@"Max-Forwards: 70"]);
}

- (void)testHeaderMatchingIsCaseInsensitiveAndTrimsWhitespace {
    NSString *trace = @"authorization: Digest response=\"aaaa\"\n"
                      @"  AUTHORIZATION  : Digest response=\"bbbb\"";

    NSString *scrubbed = [CallWaveLog scrubAuthorizationInMessage:trace];

    XCTAssertFalse([scrubbed containsString:@"aaaa"]);
    XCTAssertFalse([scrubbed containsString:@"bbbb"]);
}

- (void)testMessagesWithoutCredentialsAreReturnedUnchanged {
    NSString *trace = @"SIP/2.0 200 OK\r\nServer: Majordom";
    XCTAssertEqualObjects([CallWaveLog scrubAuthorizationInMessage:trace], trace);

    // "Authorization" inside a body line that is not a header stays untouched.
    NSString *body = @"note: call the Authorization desk on Monday";
    XCTAssertEqualObjects([CallWaveLog scrubAuthorizationInMessage:body], body);
}

- (void)testCredentialsStayScrubbedWhenIdentifierRedactionIsDisabled {
    CallWaveLog.redactsIdentifiers = NO;
    NSString *trace = @"Authorization: Digest username=\"100\", "
                       "response=\"1f4a9c2b\", nonce=\"secret\"";

    NSString *scrubbed = [CallWaveLog scrubAuthorizationInMessage:trace];
    XCTAssertEqualObjects(scrubbed, @"Authorization: <redacted>");
    XCTAssertFalse([scrubbed containsString:@"100"]);
    XCTAssertFalse([scrubbed containsString:@"1f4a9c2b"]);
    XCTAssertFalse([scrubbed containsString:@"secret"]);
}

- (void)testFoldedAuthorizationContinuationIsScrubbed {
    CallWaveLog.redactsIdentifiers = NO;
    NSString *trace = @"Authorization: Digest username=\"100\",\r\n"
                       " response=\"1f4a9c2b\", nonce=\"secret\"\r\n"
                       "Max-Forwards: 70";

    NSString *scrubbed = [CallWaveLog scrubAuthorizationInMessage:trace];
    XCTAssertEqualObjects(scrubbed,
                          @"Authorization: <redacted>\nMax-Forwards: 70");
    XCTAssertFalse([scrubbed containsString:@"response="]);
    XCTAssertFalse([scrubbed containsString:@"secret"]);
}

- (void)testTrailingShapeIsPreserved {
    NSString *withNewline = @"Authorization: Digest response=\"aa\"\n";
    NSString *scrubbedWith = [CallWaveLog scrubAuthorizationInMessage:withNewline];
    XCTAssertTrue([scrubbedWith hasSuffix:@"\n"]);

    NSString *withoutNewline = @"Authorization: Digest response=\"aa\"";
    NSString *scrubbedWithout = [CallWaveLog scrubAuthorizationInMessage:withoutNewline];
    XCTAssertFalse([scrubbedWithout hasSuffix:@"\n"]);
}

@end
