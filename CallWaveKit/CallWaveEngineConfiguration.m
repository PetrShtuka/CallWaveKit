#import "CallWaveEngineConfiguration.h"

@implementation CallWaveEngineConfiguration

- (instancetype)init {
    self = [super init];
    if (self) {
        _maximumCalls = 1;
        _logLevel = CallWaveLogLevelWarning;
        _ICEEnabled = NO;
        _STUNServers = @[];
        _preferredCodecs = @[];
        _verifiesTLSCertificate = YES;
        _echoCancellationTailMilliseconds = 200;
        _voiceActivityDetectionEnabled = NO;
        _handlesNetworkChanges = YES;
    }
    return self;
}

+ (instancetype)defaultConfiguration {
    return [[self alloc] init];
}

- (void)setMaximumCalls:(NSUInteger)maximumCalls {
    _maximumCalls = MAX(maximumCalls, (NSUInteger)1);
}

- (void)setSTUNServers:(NSArray<NSString *> *)STUNServers {
    _STUNServers = [STUNServers copy] ?: @[];
}

- (void)setPreferredCodecs:(NSArray<NSString *> *)preferredCodecs {
    _preferredCodecs = [preferredCodecs copy] ?: @[];
}

- (id)copyWithZone:(NSZone *)zone {
    CallWaveEngineConfiguration *copy = [[CallWaveEngineConfiguration allocWithZone:zone] init];
    copy.maximumCalls = self.maximumCalls;
    copy.logLevel = self.logLevel;
    copy.userAgent = self.userAgent;
    copy.ICEEnabled = self.ICEEnabled;
    copy.STUNServers = self.STUNServers;
    copy.preferredCodecs = self.preferredCodecs;
    copy.verifiesTLSCertificate = self.verifiesTLSCertificate;
    copy.echoCancellationTailMilliseconds = self.echoCancellationTailMilliseconds;
    copy.voiceActivityDetectionEnabled = self.voiceActivityDetectionEnabled;
    copy.handlesNetworkChanges = self.handlesNetworkChanges;
    return copy;
}

@end
