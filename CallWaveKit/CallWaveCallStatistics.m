#import "CallWaveCallStatisticsInternal.h"

@implementation CallWaveCallStatistics

- (instancetype)initWithDuration:(NSTimeInterval)duration
                     packetsSent:(NSUInteger)packetsSent
                 packetsReceived:(NSUInteger)packetsReceived
              packetsLostInbound:(NSUInteger)packetsLostInbound
             packetsLostOutbound:(NSUInteger)packetsLostOutbound
                          jitter:(NSTimeInterval)jitter
                   roundTripTime:(NSTimeInterval)roundTripTime
                           codec:(NSString *)codec
                       clockRate:(NSUInteger)clockRate {
    self = [super init];
    if (self) {
        _duration = duration;
        _packetsSent = packetsSent;
        _packetsReceived = packetsReceived;
        _packetsLostInbound = packetsLostInbound;
        _packetsLostOutbound = packetsLostOutbound;
        _jitter = jitter;
        _roundTripTime = roundTripTime;
        _codec = [codec copy];
        _clockRate = clockRate;
    }
    return self;
}

- (double)inboundLossFraction {
    NSUInteger total = self.packetsReceived + self.packetsLostInbound;
    return total > 0 ? (double)self.packetsLostInbound / (double)total : 0.0;
}

- (double)outboundLossFraction {
    NSUInteger total = self.packetsSent + self.packetsLostOutbound;
    return total > 0 ? (double)self.packetsLostOutbound / (double)total : 0.0;
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<%@: %@ %luHz, %.0fs, rx %lu (-%lu, %.1f%%), tx %lu (-%lu, %.1f%%), "
            @"jitter %.0fms, rtt %.0fms>",
            NSStringFromClass(self.class),
            self.codec ?: @"none",
            (unsigned long)self.clockRate,
            self.duration,
            (unsigned long)self.packetsReceived,
            (unsigned long)self.packetsLostInbound,
            self.inboundLossFraction * 100.0,
            (unsigned long)self.packetsSent,
            (unsigned long)self.packetsLostOutbound,
            self.outboundLossFraction * 100.0,
            self.jitter * 1000.0,
            self.roundTripTime * 1000.0];
}

@end
