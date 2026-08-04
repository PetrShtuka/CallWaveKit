#import "CallWaveTURNConfiguration.h"

@implementation CallWaveTURNConfiguration

- (instancetype)initWithServer:(NSString *)server
                      transport:(CallWaveTransport)transport
                       username:(NSString *)username
                       password:(NSString *)password {
    self = [super init];
    if (self) {
        _server = [server copy] ?: @"";
        _transport = transport;
        _username = [username copy] ?: @"";
        _password = [password copy] ?: @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[CallWaveTURNConfiguration allocWithZone:zone]
            initWithServer:self.server
                 transport:self.transport
                  username:self.username
                  password:self.password];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: server=%@ transport=%ld user=%@ password=<redacted>>",
            NSStringFromClass(self.class),
            self.server.length > 0 ? @"<configured>" : @"<empty>", (long)self.transport,
            self.username.length > 0 ? @"<redacted>" : @"<empty>"];
}

@end
