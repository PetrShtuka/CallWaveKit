#import "CallWaveCallQualityInternal.h"

#import "CallWaveCallStatistics.h"
#import "CallWaveEngineConfiguration.h"

/// Loss and jitter only become meaningful once at least a second of typical
/// 50 pps audio has been seen; below that the counters are dominated by the
/// call set-up transient.
static NSUInteger const CallWaveCallQualityMinimumPackets = 20;

CallWaveCallQualityWarning
CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMask bit) {
    switch (bit) {
        case CallWaveCallQualityWarningMaskPacketLoss:
            return CallWaveCallQualityWarningPacketLoss;
        case CallWaveCallQualityWarningMaskJitter:
            return CallWaveCallQualityWarningHighJitter;
        case CallWaveCallQualityWarningMaskRoundTripTime:
            return CallWaveCallQualityWarningHighRoundTripTime;
        case CallWaveCallQualityWarningMaskNoMedia:
            return CallWaveCallQualityWarningNoMedia;
        default:
            return 0;
    }
}

CallWaveCallQualityWarningMask
CallWaveEvaluateCallQuality(CallWaveCallStatistics *statistics,
                            CallWaveEngineConfiguration *engine) {
    if (statistics == nil || engine == nil) {
        return CallWaveCallQualityWarningMaskNone;
    }

    CallWaveCallQualityWarningMask mask = CallWaveCallQualityWarningMaskNone;

    if (engine.qualityWarningsEnabled) {
        NSUInteger inboundTotal = statistics.packetsReceived + statistics.packetsLostInbound;
        if (inboundTotal >= CallWaveCallQualityMinimumPackets &&
            statistics.inboundLossFraction > engine.qualityWarningPacketLossThreshold) {
            mask |= CallWaveCallQualityWarningMaskPacketLoss;
        }
        if (statistics.packetsReceived >= CallWaveCallQualityMinimumPackets &&
            statistics.jitter > engine.qualityWarningJitterThreshold) {
            mask |= CallWaveCallQualityWarningMaskJitter;
        }
        // RTT is 0 until the first RTCP report arrives; 0 never trips the
        // threshold, so no extra guard is needed here.
        if (statistics.roundTripTime > engine.qualityWarningRoundTripTimeThreshold) {
            mask |= CallWaveCallQualityWarningMaskRoundTripTime;
        }
    }

    if (engine.noMediaTimeout > 0 &&
        statistics.packetsReceived == 0 &&
        statistics.duration >= engine.noMediaTimeout) {
        mask |= CallWaveCallQualityWarningMaskNoMedia;
    }

    return mask;
}
