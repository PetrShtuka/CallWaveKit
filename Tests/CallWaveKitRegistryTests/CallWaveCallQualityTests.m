#import <XCTest/XCTest.h>

#import "CallWaveCallQualityInternal.h"
#import "CallWaveCallStatisticsInternal.h"
#import "CallWaveEngineConfiguration.h"

// The evaluator is a pure function over a statistics snapshot and the engine
// thresholds, so every rule is exercised here without a live SIP call. The
// client-level latching and event emission are thin wiring on top of it.
@interface CallWaveCallQualityTests : XCTestCase
@end

@implementation CallWaveCallQualityTests

- (CallWaveCallStatistics *)statisticsWithReceived:(NSUInteger)received
                                       lostInbound:(NSUInteger)lostInbound
                                          duration:(NSTimeInterval)duration
                                            jitter:(NSTimeInterval)jitter
                                               rtt:(NSTimeInterval)rtt {
    return [[CallWaveCallStatistics alloc]
            initWithDuration:duration
                 packetsSent:received
             packetsReceived:received
          packetsLostInbound:lostInbound
         packetsLostOutbound:0
                      jitter:jitter
               roundTripTime:rtt
                       codec:@"PCMA"
                   clockRate:8000];
}

- (CallWaveCallStatistics *)healthyStatistics {
    return [self statisticsWithReceived:500 lostInbound:0 duration:10
                                 jitter:0.005 rtt:0.02];
}

- (void)testHealthyCallProducesNoWarnings {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallQualityWarningMask mask =
        CallWaveEvaluateCallQuality([self healthyStatistics], engine);
    XCTAssertEqual(mask, CallWaveCallQualityWarningMaskNone);
}

- (void)testPacketLossAboveThresholdWarns {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    // 10 % loss against the 5 % default threshold.
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:450 lostInbound:50 duration:10 jitter:0.005 rtt:0.02];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertTrue(mask & CallWaveCallQualityWarningMaskPacketLoss);
}

- (void)testPacketLossNeedsAMinimalSample {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    // 100 % loss, but only a handful of packets into the call.
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:0 lostInbound:5 duration:0.2 jitter:0 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertFalse(mask & CallWaveCallQualityWarningMaskPacketLoss);
}

- (void)testHighJitterWarns {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:500 lostInbound:0 duration:10 jitter:0.08 rtt:0.02];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertTrue(mask & CallWaveCallQualityWarningMaskJitter);
}

- (void)testHighRoundTripTimeWarns {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:500 lostInbound:0 duration:10 jitter:0.005 rtt:0.5];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertTrue(mask & CallWaveCallQualityWarningMaskRoundTripTime);
}

- (void)testZeroRoundTripTimeNeverWarns {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.qualityWarningRoundTripTimeThreshold = 0.0;
    // No RTCP report yet: RTT reads 0 and must not trip even a zero threshold.
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:500 lostInbound:0 duration:10 jitter:0.005 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertFalse(mask & CallWaveCallQualityWarningMaskRoundTripTime);
}

- (void)testDisabledWarningsStaySilent {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.qualityWarningsEnabled = NO;
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:100 lostInbound:400 duration:10 jitter:0.5 rtt:2.0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertEqual(mask & (CallWaveCallQualityWarningMaskPacketLoss |
                           CallWaveCallQualityWarningMaskJitter |
                           CallWaveCallQualityWarningMaskRoundTripTime),
                   CallWaveCallQualityWarningMaskNone);
}

- (void)testNoMediaWatchdogFiresAfterTimeout {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:0 lostInbound:0 duration:6 jitter:0 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertTrue(mask & CallWaveCallQualityWarningMaskNoMedia);
}

- (void)testNoMediaWatchdogWaitsForTheTimeout {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:0 lostInbound:0 duration:2 jitter:0 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertFalse(mask & CallWaveCallQualityWarningMaskNoMedia);
}

- (void)testNoMediaWatchdogStaysQuietOncePacketsFlow {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:1 lostInbound:0 duration:60 jitter:0 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertFalse(mask & CallWaveCallQualityWarningMaskNoMedia);
}

- (void)testNoMediaWatchdogCanBeDisabled {
    CallWaveEngineConfiguration *engine = [CallWaveEngineConfiguration defaultConfiguration];
    engine.noMediaTimeout = 0;
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:0 lostInbound:0 duration:60 jitter:0 rtt:0];
    CallWaveCallQualityWarningMask mask = CallWaveEvaluateCallQuality(statistics, engine);
    XCTAssertEqual(mask, CallWaveCallQualityWarningMaskNone);
}

- (void)testMaskBitsMapToPublicWarnings {
    XCTAssertEqual(CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMaskPacketLoss),
                   CallWaveCallQualityWarningPacketLoss);
    XCTAssertEqual(CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMaskJitter),
                   CallWaveCallQualityWarningHighJitter);
    XCTAssertEqual(CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMaskRoundTripTime),
                   CallWaveCallQualityWarningHighRoundTripTime);
    XCTAssertEqual(CallWaveCallQualityWarningForMaskBit(CallWaveCallQualityWarningMaskNoMedia),
                   CallWaveCallQualityWarningNoMedia);
}

- (void)testExperimentalEstimatedMOSIsHighForAHealthyCall {
    double mos = [self healthyStatistics].experimentalEstimatedMOS;
    XCTAssertGreaterThan(mos, 4.0);
    XCTAssertLessThanOrEqual(mos, 4.5);
}

- (void)testExperimentalEstimatedMOSDropsWithLossAndDelay {
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:300 lostInbound:200 duration:40 jitter:0.1 rtt:0.6];
    double mos = statistics.experimentalEstimatedMOS;
    XCTAssertGreaterThanOrEqual(mos, 1.0);
    XCTAssertLessThan(mos, 3.0);
}

- (void)testExperimentalEstimatedMOSIsUnknownWithoutMedia {
    CallWaveCallStatistics *statistics =
        [self statisticsWithReceived:0 lostInbound:0 duration:3 jitter:0 rtt:0];
    XCTAssertEqual(statistics.experimentalEstimatedMOS, 0.0);
}

@end
