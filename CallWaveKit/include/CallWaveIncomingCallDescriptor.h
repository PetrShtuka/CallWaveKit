#import <Foundation/Foundation.h>

// `NS_SWIFT_SENDABLE` arrived with the Xcode 15 SDK; older SDKs simply lose the
// annotation, which costs Swift concurrency checking and nothing else.
#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

/// What a VoIP push says about the call it is waking the application for.
NS_SWIFT_SENDABLE
@interface CallWaveIncomingCallDescriptor : NSObject

@property (nonatomic, strong, readonly) NSUUID *uuid;
/// `nil` falls back to `CallWaveClient.defaultCallerName`.
@property (nonatomic, copy, readonly, nullable) NSString *caller;
/// `YES` when the payload announces that the caller hung up before anyone
/// answered, not a new incoming call. A cancellation is never reported to
/// CallKit as an incoming call; it ends or suppresses the call it names.
@property (nonatomic, assign, readonly, getter=isCancellation) BOOL cancellation;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithUUID:(NSUUID *)uuid
                      caller:(nullable NSString *)caller;
- (instancetype)initWithUUID:(NSUUID *)uuid
                      caller:(nullable NSString *)caller
                cancellation:(BOOL)cancellation NS_DESIGNATED_INITIALIZER;
+ (instancetype)descriptorWithUUID:(NSUUID *)uuid caller:(nullable NSString *)caller;
/// The caller hung up before an answer: the incoming call screen for `uuid`
/// must come down, and the INVITE that may still arrive must be refused.
+ (instancetype)cancellationDescriptorWithUUID:(NSUUID *)uuid;

@end

/// Turns a push payload of an arbitrary shape into a call description. Return
/// `nil` to fall back to CallWaveKit's own parsing of `data.uuid` and
/// `data.callerID`.
typedef CallWaveIncomingCallDescriptor * _Nullable (^CallWavePushPayloadParser)(NSDictionary *payload);

NS_ASSUME_NONNULL_END
