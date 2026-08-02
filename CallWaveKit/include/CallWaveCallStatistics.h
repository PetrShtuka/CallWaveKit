#import <Foundation/Foundation.h>

// `NS_SWIFT_SENDABLE` arrived with the Xcode 15 SDK; older SDKs simply lose the
// annotation, which costs Swift concurrency checking and nothing else.
#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

/// A snapshot of the RTP/RTCP counters of one audio stream, taken when
/// `-statisticsForCallWithUUID:` was called.
NS_SWIFT_SENDABLE
@interface CallWaveCallStatistics : NSObject

/// How long the call has been connected. `0` before the media starts.
@property (nonatomic, assign, readonly) NSTimeInterval duration;

@property (nonatomic, assign, readonly) NSUInteger packetsSent;
@property (nonatomic, assign, readonly) NSUInteger packetsReceived;
/// Packets the device never received, as counted locally.
@property (nonatomic, assign, readonly) NSUInteger packetsLostInbound;
/// Packets the peer reported as missing over RTCP.
@property (nonatomic, assign, readonly) NSUInteger packetsLostOutbound;

/// `packetsLostInbound / (packetsReceived + packetsLostInbound)`, in `0…1`.
@property (nonatomic, assign, readonly) double inboundLossFraction;
/// `packetsLostOutbound / (packetsSent + packetsLostOutbound)`, in `0…1`.
@property (nonatomic, assign, readonly) double outboundLossFraction;

/// Mean inbound jitter.
@property (nonatomic, assign, readonly) NSTimeInterval jitter;
/// Mean round-trip time from RTCP, or `0` when the peer sends no reports.
@property (nonatomic, assign, readonly) NSTimeInterval roundTripTime;

/// Negotiated encoding, e.g. `PCMA`. `nil` before the media starts.
@property (nonatomic, copy, readonly, nullable) NSString *codec;
@property (nonatomic, assign, readonly) NSUInteger clockRate;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
