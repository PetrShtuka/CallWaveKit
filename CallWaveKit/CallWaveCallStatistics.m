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

- (double)estimatedMOS {
    if (self.packetsReceived == 0) {
        return 0.0;
    }
    // Approximate mouth-to-ear delay: codec/device budget plus half the RTT
    // plus a de-jitter buffer of two mean jitter spans.
    double delayMilliseconds = 10.0 + self.roundTripTime * 500.0 + self.jitter * 2000.0;
    double delayImpairment = 0.024 * delayMilliseconds;
    if (delayMilliseconds > 177.3) {
        delayImpairment += 0.11 * (delayMilliseconds - 177.3);
    }
    double lossPercent = self.inboundLossFraction * 100.0;
    double rFactor = 93.2 - lossPercent * 2.5 - delayImpairment;
    rFactor = MIN(MAX(rFactor, 0.0), 100.0);
    double mos = 1.0 + 0.035 * rFactor +
                 rFactor * (rFactor - 60.0) * (100.0 - rFactor) * 7e-6;
    return MIN(MAX(mos, 1.0), 4.5);
}

- (NSString *)description {
    return [NSString stringWithFormat:
            @"<%@: %@ %luHz, %.0fs, rx %lu (-%lu, %.1f%%), tx %lu (-%lu, %.1f%%), "
            @"jitter %.0fms, rtt %.0fms, mos %.1f>",
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
            self.roundTripTime * 1000.0,
            self.estimatedMOS];
}

@end
