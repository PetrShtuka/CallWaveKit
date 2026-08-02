#import "CallWaveConfiguration.h"

static NSUInteger CallWaveDefaultPortForTransport(CallWaveTransport transport) {
    return transport == CallWaveTransportTLS ? 5061 : 5060;
}

static NSString *CallWaveTransportURIParameter(CallWaveTransport transport) {
    switch (transport) {
        case CallWaveTransportTCP:
            return @";transport=tcp";
        case CallWaveTransportTLS:
            return @";transport=tls";
        case CallWaveTransportUDP:
            break;
    }
    return @"";
}

static NSString *CallWaveTrim(NSString *_Nullable value) {
    return [value stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

@implementation CallWaveConfigurationBuilder

- (instancetype)init {
    self = [super init];
    if (self) {
        _host = @"";
        _port = 0;
        _transport = CallWaveTransportUDP;
        _username = @"";
        _password = @"";
        _includesCallsInRecents = NO;
        _registrationExpiry = 0;
        _keepAliveInterval = 0;
        _mediaEncryption = CallWaveMediaEncryptionDisabled;
        _additionalRegistrationHeaders = @{};
    }
    return self;
}

- (void)setHost:(NSString *)host {
    _host = [CallWaveTrim(host) copy];
}

- (void)setUsername:(NSString *)username {
    _username = [CallWaveTrim(username) copy];
}

- (void)setPassword:(NSString *)password {
    _password = [password copy] ?: @"";
}

- (void)setAdditionalRegistrationHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    _additionalRegistrationHeaders = [headers copy] ?: @{};
}

@end

@implementation CallWaveConfiguration

- (instancetype)initWithBuilder:(NS_NOESCAPE void (^)(CallWaveConfigurationBuilder *))block {
    self = [super init];
    if (self) {
        CallWaveConfigurationBuilder *builder = [[CallWaveConfigurationBuilder alloc] init];
        if (block != nil) {
            block(builder);
        }
        _host = [builder.host copy];
        _port = builder.port;
        _transport = builder.transport;
        _username = [builder.username copy];
        _password = [builder.password copy];
        _includesCallsInRecents = builder.includesCallsInRecents;

        NSString *authentication = CallWaveTrim(builder.authenticationUsername);
        _authenticationUsername = authentication.length > 0 ? [authentication copy] : [_username copy];
        NSString *realm = CallWaveTrim(builder.realm);
        _realm = realm.length > 0 ? [realm copy] : @"*";
        NSString *proxy = CallWaveTrim(builder.outboundProxy);
        _outboundProxy = proxy.length > 0 ? [proxy copy] : nil;
        _registrationExpiry = builder.registrationExpiry > 0 ? builder.registrationExpiry : 300;
        _keepAliveInterval = builder.keepAliveInterval > 0 ? builder.keepAliveInterval : 15;
        _mediaEncryption = builder.mediaEncryption;
        _additionalRegistrationHeaders = [builder.additionalRegistrationHeaders copy];
    }
    return self;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(NSUInteger)port
                   transport:(CallWaveTransport)transport
                    username:(NSString *)username
                    password:(NSString *)password
      includesCallsInRecents:(BOOL)includesCallsInRecents {
    return [self initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
        builder.host = host;
        builder.port = port;
        builder.transport = transport;
        builder.username = username;
        builder.password = password;
        builder.includesCallsInRecents = includesCallsInRecents;
    }];
}

- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents {
    NSString *value = CallWaveTrim(domain);
    NSString *host = value;
    NSUInteger port = 0;

    // Only a trailing `:port` is split. IPv6 literals keep their colons and are
    // expected to arrive bracketed, as SIP URIs require.
    if (![value hasPrefix:@"["]) {
        NSRange colon = [value rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location != NSNotFound) {
            NSString *tail = [value substringFromIndex:NSMaxRange(colon)];
            NSScanner *scanner = [NSScanner scannerWithString:tail];
            int parsed = 0;
            if ([scanner scanInt:&parsed] && scanner.isAtEnd && parsed > 0) {
                host = [value substringToIndex:colon.location];
                port = (NSUInteger)parsed;
            }
        }
    }

    return [self initWithHost:host
                         port:port
                    transport:CallWaveTransportUDP
                     username:username
                     password:password
       includesCallsInRecents:includesCallsInRecents];
}

- (instancetype)configurationByApplying:(NS_NOESCAPE void (^)(CallWaveConfigurationBuilder *))block {
    return [[CallWaveConfiguration alloc] initWithBuilder:^(CallWaveConfigurationBuilder *builder) {
        builder.host = self.host;
        builder.port = self.port;
        builder.transport = self.transport;
        builder.username = self.username;
        builder.password = self.password;
        builder.includesCallsInRecents = self.includesCallsInRecents;
        builder.authenticationUsername = self.authenticationUsername;
        builder.realm = self.realm;
        builder.outboundProxy = self.outboundProxy;
        builder.registrationExpiry = self.registrationExpiry;
        builder.keepAliveInterval = self.keepAliveInterval;
        builder.mediaEncryption = self.mediaEncryption;
        builder.additionalRegistrationHeaders = self.additionalRegistrationHeaders;
        if (block != nil) {
            block(builder);
        }
    }];
}

- (NSString *)domain {
    return self.port > 0
        ? [NSString stringWithFormat:@"%@:%lu", self.host, (unsigned long)self.port]
        : self.host;
}

- (NSString *)identityURI {
    return [NSString stringWithFormat:@"sip:%@@%@", self.username, self.host];
}

- (NSString *)registrarURI {
    return [NSString stringWithFormat:@"sip:%@:%lu%@",
            self.host,
            (unsigned long)(self.port > 0 ? self.port : CallWaveDefaultPortForTransport(self.transport)),
            CallWaveTransportURIParameter(self.transport)];
}

- (BOOL)isEqualToConfiguration:(CallWaveConfiguration *)other {
    if (other == nil) {
        return NO;
    }
    if (other == self) {
        return YES;
    }
    return [self.host isEqualToString:other.host] &&
           self.port == other.port &&
           self.transport == other.transport &&
           [self.username isEqualToString:other.username] &&
           [self.password isEqualToString:other.password] &&
           [self.authenticationUsername isEqualToString:other.authenticationUsername] &&
           [self.realm isEqualToString:other.realm] &&
           (self.outboundProxy == other.outboundProxy ||
            [self.outboundProxy isEqualToString:other.outboundProxy]) &&
           self.registrationExpiry == other.registrationExpiry &&
           self.keepAliveInterval == other.keepAliveInterval &&
           self.mediaEncryption == other.mediaEncryption &&
           [self.additionalRegistrationHeaders isEqualToDictionary:other.additionalRegistrationHeaders];
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:CallWaveConfiguration.class]) {
        return NO;
    }
    CallWaveConfiguration *other = object;
    return [self isEqualToConfiguration:other] &&
           self.includesCallsInRecents == other.includesCallsInRecents;
}

- (NSUInteger)hash {
    return self.host.hash ^ self.username.hash ^ self.port ^ (NSUInteger)self.transport;
}

- (id)copyWithZone:(NSZone *)zone {
    // Immutable.
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@ via %@>",
            NSStringFromClass(self.class), self.identityURI, self.registrarURI];
}

@end
