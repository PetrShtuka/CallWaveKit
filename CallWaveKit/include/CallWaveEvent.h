#import <Foundation/Foundation.h>
#import <CallKit/CallKit.h>

#import "CallWaveTypes.h"

// `NS_SWIFT_SENDABLE` arrived with the Xcode 15 SDK; older SDKs simply lose the
// annotation, which costs Swift concurrency checking and nothing else.
#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CallWaveEventType) {
    CallWaveEventTypeRegistrationStateChanged,
    CallWaveEventTypeIncomingCall,
    CallWaveEventTypeCallStateChanged,
    CallWaveEventTypeCallEnded,
    CallWaveEventTypeVoIPPushTokenUpdated,
};

/// One notification from `CallWaveClient`, delivered to every block registered
/// with `-addEventObserver:`. This is the same information the delegate gets,
/// in a form that survives being put on an `AsyncStream`.
///
/// Events are always delivered on the main queue.
NS_SWIFT_SENDABLE
@interface CallWaveEvent : NSObject

@property (nonatomic, assign, readonly) CallWaveEventType type;
@property (nonatomic, strong, readonly, nullable) NSUUID *callUUID;
/// Meaningful for `…IncomingCall` and `…CallStateChanged`.
@property (nonatomic, assign, readonly) CallWaveCallState callState;
/// Meaningful for `…RegistrationStateChanged`.
@property (nonatomic, assign, readonly) CallWaveRegistrationState registrationState;
/// SIP status code for `…RegistrationStateChanged`, otherwise `0`.
@property (nonatomic, assign, readonly) NSInteger statusCode;
/// Display name for `…IncomingCall`.
@property (nonatomic, copy, readonly, nullable) NSString *caller;
/// Hexadecimal token for `…VoIPPushTokenUpdated`.
@property (nonatomic, copy, readonly, nullable) NSString *pushToken;
/// Meaningful for `…CallEnded`.
@property (nonatomic, assign, readonly) CXCallEndedReason endedReason;
/// Set when the event reports a failure, e.g. a rejected registration.
@property (nonatomic, strong, readonly, nullable) NSError *error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
