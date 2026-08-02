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

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithUUID:(NSUUID *)uuid
                      caller:(nullable NSString *)caller NS_DESIGNATED_INITIALIZER;
+ (instancetype)descriptorWithUUID:(NSUUID *)uuid caller:(nullable NSString *)caller;

@end

/// Turns a push payload of an arbitrary shape into a call description. Return
/// `nil` to fall back to CallWaveKit's own parsing of `data.uuid` and
/// `data.callerID`.
typedef CallWaveIncomingCallDescriptor * _Nullable (^CallWavePushPayloadParser)(NSDictionary *payload);

NS_ASSUME_NONNULL_END
