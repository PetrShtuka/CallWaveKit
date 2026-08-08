#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class CallWaveCallStatistics;
@class CallWaveEngineConfiguration;

/// Bitmask form of `CallWaveCallQualityWarning`, used so the per-call latch in
/// `CallWaveClient` can remember several fired warnings at once.
typedef NS_OPTIONS(NSUInteger, CallWaveCallQualityWarningMask) {
    CallWaveCallQualityWarningMaskNone = 0,
    CallWaveCallQualityWarningMaskPacketLoss = 1 << 0,
    CallWaveCallQualityWarningMaskJitter = 1 << 1,
    CallWaveCallQualityWarningMaskRoundTripTime = 1 << 2,
    CallWaveCallQualityWarningMaskNoMedia = 1 << 3,
};

/// Maps a single mask bit to its public warning value.
FOUNDATION_EXPORT CallWaveCallQualityWarning
CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMask bit);

/// Pure threshold evaluation, kept out of `CallWaveClient` so the rules are
/// testable without a live SIP call. Returns the warnings the snapshot
/// crosses; latching and event emission are the caller's job.
FOUNDATION_EXPORT CallWaveCallQualityWarningMask
CallWaveEvaluateCallQuality(CallWaveCallStatistics *statistics,
                            CallWaveEngineConfiguration *engine);

NS_ASSUME_NONNULL_END
