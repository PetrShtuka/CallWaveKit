#import "CallWaveLoopbackIntercom.h"

#import "CallWaveAnswerTimeline.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation CallWaveLoopbackPacket
- (instancetype)initWithMessage:(NSString *)message receivedAt:(uint64_t)receivedAt {
    self = [super init];
    if (self) {
        _message = [message copy];
        _receivedAt = receivedAt;
    }
    return self;
}
@end

@implementation CallWaveLoopbackIntercom {
    int _socket;
    int _enginePort;
    NSMutableArray<CallWaveLoopbackPacket *> *_packets;
    NSThread *_reader;
    BOOL _closed;
}

- (instancetype)initWithEnginePort:(int)enginePort {
    self = [super init];
    if (self) {
        _enginePort = enginePort;
        _packets = [NSMutableArray array];
        _socket = socket(AF_INET, SOCK_DGRAM, 0);
        if (_socket < 0) {
            return nil;
        }
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t length = sizeof(address);
        if (bind(_socket, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            getsockname(_socket, (struct sockaddr *)&address, &length) != 0) {
            close(_socket);
            return nil;
        }
        _localPort = ntohs(address.sin_port);
        struct timeval timeout = { .tv_sec = 0, .tv_usec = 50000 };
        setsockopt(_socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

        __weak typeof(self) weakSelf = self;
        int fd = _socket;
        _reader = [[NSThread alloc] initWithBlock:^{
            char buffer[8192];
            while (!NSThread.currentThread.isCancelled) {
                struct sockaddr_in from = {0};
                socklen_t fromLength = sizeof(from);
                ssize_t count = recvfrom(fd, buffer, sizeof(buffer) - 1, 0,
                                         (struct sockaddr *)&from, &fromLength);
                if (count <= 0) {
                    continue;
                }
                uint64_t receivedAt = CallWaveMonotonicNanoseconds();
                buffer[count] = '\0';
                NSString *message = [NSString stringWithUTF8String:buffer] ?: @"";
                [weakSelf receivedMessage:message at:receivedAt from:from];
            }
        }];
        _reader.qualityOfService = NSQualityOfServiceUserInteractive;
        [_reader start];
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    @synchronized (self) {
        if (_closed) {
            return;
        }
        _closed = YES;
    }
    [_reader cancel];
    // The reader wakes up within its receive timeout and sees the cancel.
    [NSThread sleepForTimeInterval:0.1];
    close(_socket);
}

- (void)receivedMessage:(NSString *)message at:(uint64_t)receivedAt from:(struct sockaddr_in)from {
    @synchronized (self) {
        [_packets addObject:[[CallWaveLoopbackPacket alloc] initWithMessage:message
                                                                 receivedAt:receivedAt]];
    }
    if ([message hasPrefix:@"BYE "]) {
        [self sendDatagram:[self okForRequest:message] to:from];
    }
}

#pragma mark - Sending

- (void)sendDatagram:(NSString *)message to:(struct sockaddr_in)address {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    sendto(_socket, data.bytes, data.length, 0, (struct sockaddr *)&address, sizeof(address));
}

- (void)send:(NSString *)message {
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)_enginePort);
    [self sendDatagram:message to:address];
}

- (NSString *)branchForCallId:(NSString *)callId {
    return [NSString stringWithFormat:@"z9hG4bK-%lx", (unsigned long)callId.hash];
}

- (void)sendInviteWithCallId:(NSString *)callId {
    NSString *body =
        @"v=0\r\no=door 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        @"t=0 0\r\nm=audio 40002 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n";
    [self send:[NSString stringWithFormat:
        @"INVITE sip:1001@127.0.0.1 SIP/2.0\r\n"
        @"Via: SIP/2.0/UDP 127.0.0.1:%d;branch=%@;rport\r\n"
        @"Max-Forwards: 70\r\n"
        @"From: \"Front door\" <sip:door@127.0.0.1>;tag=doortag\r\n"
        @"To: <sip:1001@127.0.0.1>\r\n"
        @"Call-ID: %@\r\n"
        @"CSeq: 1 INVITE\r\n"
        @"Contact: <sip:door@127.0.0.1:%d>\r\n"
        @"Content-Type: application/sdp\r\n"
        @"Content-Length: %lu\r\n\r\n%@",
        self.localPort, [self branchForCallId:callId], callId, self.localPort,
        (unsigned long)body.length, body]];
}

- (void)sendCancelWithCallId:(NSString *)callId {
    [self send:[NSString stringWithFormat:
        @"CANCEL sip:1001@127.0.0.1 SIP/2.0\r\n"
        @"Via: SIP/2.0/UDP 127.0.0.1:%d;branch=%@;rport\r\n"
        @"Max-Forwards: 70\r\n"
        @"From: \"Front door\" <sip:door@127.0.0.1>;tag=doortag\r\n"
        @"To: <sip:1001@127.0.0.1>\r\n"
        @"Call-ID: %@\r\n"
        @"CSeq: 1 CANCEL\r\n"
        @"Content-Length: 0\r\n\r\n",
        self.localPort, [self branchForCallId:callId], callId]];
}

+ (nullable NSString *)headerNamed:(NSString *)name inMessage:(NSString *)message {
    NSString *prefix = [name stringByAppendingString:@":"];
    for (NSString *line in [message componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:prefix.lowercaseString]) {
            return [[line substringFromIndex:prefix.length]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
    }
    return nil;
}

- (void)sendACKForResponse:(NSString *)response callId:(NSString *)callId {
    NSString *to = [CallWaveLoopbackIntercom headerNamed:@"To" inMessage:response] ?: @"";
    NSString *contact = [CallWaveLoopbackIntercom headerNamed:@"Contact" inMessage:response] ?: @"";
    NSRange open = [contact rangeOfString:@"<"];
    NSRange shut = [contact rangeOfString:@">"];
    NSString *target = open.location != NSNotFound && shut.location != NSNotFound
        ? [contact substringWithRange:NSMakeRange(NSMaxRange(open),
                                                  shut.location - NSMaxRange(open))]
        : @"sip:1001@127.0.0.1";
    [self send:[NSString stringWithFormat:
        @"ACK %@ SIP/2.0\r\n"
        @"Via: SIP/2.0/UDP 127.0.0.1:%d;branch=z9hG4bK-ack-%lx;rport\r\n"
        @"Max-Forwards: 70\r\n"
        @"From: \"Front door\" <sip:door@127.0.0.1>;tag=doortag\r\n"
        @"To: %@\r\n"
        @"Call-ID: %@\r\n"
        @"CSeq: 1 ACK\r\n"
        @"Content-Length: 0\r\n\r\n",
        target, self.localPort, (unsigned long)callId.hash, to, callId]];
}

- (NSString *)okForRequest:(NSString *)request {
    NSMutableString *response = [NSMutableString stringWithString:@"SIP/2.0 200 OK\r\n"];
    for (NSString *line in [request componentsSeparatedByString:@"\r\n"]) {
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"via:"] || [lower hasPrefix:@"from:"] ||
            [lower hasPrefix:@"to:"] || [lower hasPrefix:@"call-id:"] ||
            [lower hasPrefix:@"cseq:"]) {
            [response appendFormat:@"%@\r\n", line];
        }
    }
    [response appendString:@"Content-Length: 0\r\n\r\n"];
    return response;
}

#pragma mark - Reading

- (CallWaveLoopbackPacket *)packetMatching:(BOOL (^)(NSString *))match {
    @synchronized (self) {
        for (CallWaveLoopbackPacket *packet in _packets) {
            if (match(packet.message)) {
                return packet;
            }
        }
    }
    return nil;
}

- (CallWaveLoopbackPacket *)waitForPacketMatching:(BOOL (^)(NSString *))match
                                           within:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        CallWaveLoopbackPacket *packet = [self packetMatching:match];
        if (packet != nil) {
            return packet;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    } while (deadline.timeIntervalSinceNow > 0);
    return nil;
}

+ (BOOL (^)(NSString *))responseToInviteWithStatus:(int)status {
    NSString *statusLine = [NSString stringWithFormat:@"SIP/2.0 %d ", status];
    return ^BOOL(NSString *message) {
        return [message hasPrefix:statusLine] && [message containsString:@"CSeq: 1 INVITE"];
    };
}

+ (BOOL (^)(NSString *))requestWithMethod:(NSString *)method {
    NSString *prefix = [method stringByAppendingString:@" "];
    return ^BOOL(NSString *message) {
        return [message hasPrefix:prefix];
    };
}

@end
