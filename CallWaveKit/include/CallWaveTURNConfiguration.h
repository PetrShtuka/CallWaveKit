#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

/// Credentials and transport for a TURN relay used by ICE.
///
/// The password is retained in memory for PJSIP but is deliberately omitted
/// from `description`, logs and diagnostics.
NS_SWIFT_SENDABLE
@interface CallWaveTURNConfiguration : NSObject <NSCopying>

/// TURN host with an optional port, e.g. `turn.example.com:3478`.
@property (nonatomic, copy, readonly) NSString *server;
/// UDP and TCP are supported for TURN. TLS requires a TLS-enabled PJSIP build.
@property (nonatomic, assign, readonly) CallWaveTransport transport;
@property (nonatomic, copy, readonly) NSString *username;
@property (nonatomic, copy, readonly) NSString *password;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithServer:(NSString *)server
                      transport:(CallWaveTransport)transport
                       username:(NSString *)username
                       password:(NSString *)password NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
