#import "CallWaveCallStatistics.h"

NS_ASSUME_NONNULL_BEGIN

@interface CallWaveCallStatistics ()

- (instancetype)initWithDuration:(NSTimeInterval)duration
                     packetsSent:(NSUInteger)packetsSent
                 packetsReceived:(NSUInteger)packetsReceived
              packetsLostInbound:(NSUInteger)packetsLostInbound
             packetsLostOutbound:(NSUInteger)packetsLostOutbound
                          jitter:(NSTimeInterval)jitter
                   roundTripTime:(NSTimeInterval)roundTripTime
                           codec:(nullable NSString *)codec
                       clockRate:(NSUInteger)clockRate NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
