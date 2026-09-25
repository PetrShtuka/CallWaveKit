#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One datagram the engine sent, stamped with `CallWaveMonotonicNanoseconds`
/// the moment it was read off the socket.
@interface CallWaveLoopbackPacket : NSObject
@property (nonatomic, copy, readonly) NSString *message;
@property (nonatomic, assign, readonly) uint64_t receivedAt;
@end

/// A UDP socket on loopback playing the intercom against the engine's own
/// transport. Reading happens on a thread of its own, so a test can block the
/// main thread and still learn when each response actually left the engine.
/// A BYE from the engine is answered `200 OK` on the spot, so teardown does
/// not have to wait out its transaction.
@interface CallWaveLoopbackIntercom : NSObject

/// `nil` when loopback UDP is unavailable.
- (nullable instancetype)initWithEnginePort:(int)enginePort;

@property (nonatomic, assign, readonly) int localPort;

- (void)sendInviteWithCallId:(NSString *)callId;
- (void)sendCancelWithCallId:(NSString *)callId;
/// The ACK for a `200 OK` to the INVITE, addressed from its Contact and To.
- (void)sendACKForResponse:(NSString *)response callId:(NSString *)callId;

/// The first packet so far that `match` accepts, without waiting.
- (nullable CallWaveLoopbackPacket *)packetMatching:(BOOL (^)(NSString *message))match;
/// Waits for one, running the current run loop meanwhile so main-queue work
/// the engine hands over keeps going.
- (nullable CallWaveLoopbackPacket *)waitForPacketMatching:(BOOL (^)(NSString *message))match
                                                    within:(NSTimeInterval)seconds;

- (void)close;

/// A final response to the INVITE with `status` (`200`, `180`, `603`…).
+ (BOOL (^)(NSString *))responseToInviteWithStatus:(int)status;
/// A request with `method` (`BYE`…) from the engine.
+ (BOOL (^)(NSString *))requestWithMethod:(NSString *)method;

@end

NS_ASSUME_NONNULL_END
