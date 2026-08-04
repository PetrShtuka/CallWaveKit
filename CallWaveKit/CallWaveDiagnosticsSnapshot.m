#import "CallWaveDiagnosticsSnapshotInternal.h"

#import "CallWaveAudioRoute.h"
#import "CallWaveCallStatistics.h"

@implementation CallWaveDiagnosticsSnapshot

- (instancetype)initWithRunning:(BOOL)running
              registrationState:(CallWaveRegistrationState)registrationState
       registrationSIPStatusCode:(NSInteger)registrationSIPStatusCode
                     networkPath:(NSString *)networkPath
                      audioRoute:(CallWaveAudioRoute *)audioRoute
                 activeCallUUIDs:(NSArray<NSUUID *> *)activeCallUUIDs
                  callStatistics:(NSDictionary<NSUUID *,CallWaveCallStatistics *> *)callStatistics {
    self = [super init];
    if (self) {
        _timestamp = [NSDate date];
        _running = running;
        _registrationState = registrationState;
        _registrationSIPStatusCode = registrationSIPStatusCode;
        _networkPath = [networkPath copy] ?: @"unknown";
        _audioRoute = audioRoute;
        _activeCallUUIDs = [activeCallUUIDs copy] ?: @[];
        _callStatistics = [callStatistics copy] ?: @{};
    }
    return self;
}

- (NSDictionary<NSString *,id> *)dictionaryRepresentation {
    NSMutableDictionary<NSString *, id> *statistics = [NSMutableDictionary dictionary];
    [self.callStatistics enumerateKeysAndObjectsUsingBlock:
     ^(NSUUID *uuid, CallWaveCallStatistics *value, BOOL *stop) {
        statistics[uuid.UUIDString] = @{
            @"duration": @(value.duration),
            @"packetsSent": @(value.packetsSent),
            @"packetsReceived": @(value.packetsReceived),
            @"packetsLostInbound": @(value.packetsLostInbound),
            @"packetsLostOutbound": @(value.packetsLostOutbound),
            @"jitter": @(value.jitter),
            @"roundTripTime": @(value.roundTripTime),
            @"codec": value.codec ?: [NSNull null],
            @"clockRate": @(value.clockRate),
        };
    }];
    NSMutableArray<NSString *> *calls = [NSMutableArray arrayWithCapacity:self.activeCallUUIDs.count];
    for (NSUUID *uuid in self.activeCallUUIDs) {
        [calls addObject:uuid.UUIDString];
    }
    return @{
        @"timestamp": @([self.timestamp timeIntervalSince1970]),
        @"running": @(self.isRunning),
        @"registrationState": @(self.registrationState),
        @"registrationSIPStatusCode": @(self.registrationSIPStatusCode),
        @"networkPath": self.networkPath,
        @"audioInputs": self.audioRoute.inputPortTypes,
        @"audioOutputs": self.audioRoute.outputPortTypes,
        @"activeCalls": calls,
        @"statistics": statistics,
    };
}

@end
