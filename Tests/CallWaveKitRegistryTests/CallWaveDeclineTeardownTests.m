#import <XCTest/XCTest.h>

#import <arpa/inet.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

#import "CallWaveClient.h"
#import "CallWaveTeardownObserverInternal.h"

#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

// A declined call is the one teardown PJSUA stops speaking about: it disconnects
// the invite session on the final response, releases the call slot, and reports
// nothing further. The 0.6.0 drain keyed on `pjsua_call_get_count()` and so
// covered the BYE path only, while its documentation claimed otherwise — the
// failure reached the field before anything caught it.
//
// Nothing short of a real INVITE proves this path, so that is what these tests
// do: a UDP socket plays the intercom against the engine's own transport on
// loopback, and the assertions are made on the bytes that come back.

@interface CallWaveDeclineDelegate : NSObject <CallWaveClientDelegate>
@property (nonatomic, strong) XCTestExpectation *ringing;
@property (nonatomic, strong, nullable) NSUUID *uuid;
@end

@implementation CallWaveDeclineDelegate
- (void)callWaveClient:(CallWaveClient *)client
    didReceiveCallFrom:(NSString *)caller
                  uuid:(NSUUID *)uuid {
    if (self.uuid == nil) {
        self.uuid = uuid;
        [self.ringing fulfill];
    }
}
@end

@interface CallWaveDeclineTeardownTests : XCTestCase
@property (nonatomic, assign) int sock;
@property (nonatomic, strong, nullable) CallWaveClient *client;
@end

@implementation CallWaveDeclineTeardownTests

- (void)setUp {
    [super setUp];
    _sock = -1;
}

- (void)tearDown {
    if (_sock >= 0) { close(_sock); _sock = -1; }
    [_client stop];
    _client = nil;
    [super tearDown];
}

/// The UDP/IPv4 port PJSUA bound, which is where the intercom would send.
- (int)enginePort {
    pjsua_transport_id ids[8];
    unsigned count = (unsigned)(sizeof(ids) / sizeof(ids[0]));
    if (pjsua_enum_transports(ids, &count) != PJ_SUCCESS) {
        return 0;
    }
    for (unsigned i = 0; i < count; i++) {
        pjsua_transport_info info;
        if (pjsua_transport_get_info(ids[i], &info) != PJ_SUCCESS) {
            continue;
        }
        if (info.type == PJSIP_TRANSPORT_UDP && info.local_name.port != 0) {
            return info.local_name.port;
        }
    }
    return 0;
}

- (int)openSocketWithPort:(int *)boundPort {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { return -1; }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(s); return -1; }
    socklen_t len = sizeof(addr);
    if (getsockname(s, (struct sockaddr *)&addr, &len) != 0) { close(s); return -1; }
    *boundPort = ntohs(addr.sin_port);
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return s;
}

- (void)send:(NSString *)message to:(int)port {
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    sendto(self.sock, data.bytes, data.length, 0,
           (struct sockaddr *)&addr, sizeof(addr));
}

/// Reads datagrams until one has `needle` on its status line, or time runs out.
- (nullable NSString *)waitForResponseContaining:(NSString *)needle
                                         within:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    char buffer[4096];
    while (deadline.timeIntervalSinceNow > 0) {
        ssize_t n = recv(self.sock, buffer, sizeof(buffer) - 1, 0);
        if (n <= 0) { continue; }
        buffer[n] = '\0';
        NSString *message = [NSString stringWithUTF8String:buffer] ?: @"";
        if ([message containsString:needle]) { return message; }
    }
    return nil;
}

- (NSString *)inviteFromPort:(int)from toPort:(int)to callId:(NSString *)callId {
    NSString *body =
        @"v=0\r\no=door 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        @"t=0 0\r\nm=audio 40002 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n";
    return [NSString stringWithFormat:
        @"INVITE sip:1001@127.0.0.1 SIP/2.0\r\n"
        @"Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bK-callwave-%@;rport\r\n"
        @"Max-Forwards: 70\r\n"
        @"From: \"Front door\" <sip:door@127.0.0.1>;tag=doortag\r\n"
        @"To: <sip:1001@127.0.0.1>\r\n"
        @"Call-ID: %@\r\n"
        @"CSeq: 1 INVITE\r\n"
        @"Contact: <sip:door@127.0.0.1:%d>\r\n"
        @"Content-Type: application/sdp\r\n"
        @"Content-Length: %lu\r\n\r\n%@",
        from, callId, callId, from, (unsigned long)body.length, body];
}

- (CallWaveClient *)startedClient {
    CallWaveConfiguration *configuration =
        [[CallWaveConfiguration alloc] initWithHost:@"127.0.0.1"
                                               port:65530
                                          transport:CallWaveTransportUDP
                                           username:@"1001"
                                           password:@"not-a-real-credential"
                             includesCallsInRecents:NO];
    CallWaveClient *client =
        [[CallWaveClient alloc] initWithConfiguration:configuration
                                              options:CallWaveIntegrationOptionNone
                                             provider:nil
                                  engineConfiguration:nil];
    NSError *error = nil;
    if (![client startWithError:&error]) {
        XCTFail(@"engine did not start: %@", error);
        return nil;
    }
    return client;
}

- (void)testObserverIsAttachedWhileTheEngineRuns {
    self.client = [self startedClient];
    XCTAssertTrue(CallWaveTeardownObserverIsRegistered(),
                  @"without the observer a declined call's ACK is neither reported "
                  @"nor waited for");
}

/// The whole reported failure in one test: decline a ringing call and prove the
/// final response reaches the wire, that it is tracked until acknowledged, and
/// that the ACK clears it.
- (void)testDecliningARingingCallPutsTheFinalResponseOnTheWireAndWaitsForItsACK {
    self.client = [self startedClient];
    int enginePort = [self enginePort];
    if (enginePort == 0) {
        XCTSkip(@"no UDP transport to talk to");
    }
    int localPort = 0;
    self.sock = [self openSocketWithPort:&localPort];
    if (self.sock < 0) {
        XCTSkip(@"loopback UDP unavailable in this environment");
    }

    CallWaveDeclineDelegate *delegate = [[CallWaveDeclineDelegate alloc] init];
    delegate.ringing = [self expectationWithDescription:@"ringing"];
    self.client.delegate = delegate;

    NSString *callId = @"callwave-decline-1";
    [self send:[self inviteFromPort:localPort toPort:enginePort callId:callId]
            to:enginePort];

    // 180 proves the INVITE was accepted and the call is ringing.
    XCTAssertNotNil([self waitForResponseContaining:@"SIP/2.0 180" within:5],
                    @"the engine never rang the call");
    [self waitForExpectations:@[delegate.ringing] timeout:5];
    XCTAssertNotNil(delegate.uuid);

    XCTestExpectation *declined = [self expectationWithDescription:@"declined"];
    [self.client endCallWithUUID:delegate.uuid completion:^(NSError *error) {
        XCTAssertNil(error);
        [declined fulfill];
    }];
    [self waitForExpectations:@[declined] timeout:5];

    // This is the assertion the field report needed: the 603 leaves the stack.
    NSString *decline = [self waitForResponseContaining:@"SIP/2.0 603" within:5];
    XCTAssertNotNil(decline, @"the 603 never reached the wire");
    XCTAssertTrue([decline containsString:callId]);

    // And it is tracked until the peer acknowledges it — the drain condition
    // that pjsua_call_get_count() cannot express.
    XCTAssertEqual(CallWaveTeardownPendingFinalResponses(), 1u,
                   @"an unACKed final response has to hold the drain open");

    // The reason the 0.6.0 drain missed this path, pinned as an assertion:
    // PJSUA has already forgotten the call while its final response is still
    // unacknowledged, so a drain keyed on this number returns immediately and
    // the account is deleted with the 603 in flight. If this ever stops being
    // zero, the extra tracking above can go.
    XCTAssertEqual(pjsua_call_get_count(), 0u,
                   @"pjsua_call_get_count() is expected to be blind to a declined "
                   @"call awaiting its ACK");

    [self send:[NSString stringWithFormat:
        @"ACK sip:1001@127.0.0.1 SIP/2.0\r\n"
        @"Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bK-callwave-%@;rport\r\n"
        @"Max-Forwards: 70\r\n"
        @"From: \"Front door\" <sip:door@127.0.0.1>;tag=doortag\r\n"
        @"To: <sip:1001@127.0.0.1>\r\n"
        @"Call-ID: %@\r\n"
        @"CSeq: 1 ACK\r\n"
        @"Content-Length: 0\r\n\r\n", localPort, callId, callId]
            to:enginePort];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (CallWaveTeardownPendingFinalResponses() > 0 &&
           deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertEqual(CallWaveTeardownPendingFinalResponses(), 0u,
                   @"the ACK has to release the drain");
}

@end
