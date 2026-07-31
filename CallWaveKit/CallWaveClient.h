#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CallWaveErrorDomain;
typedef void (^CallWaveCompletion)(NSError * _Nullable error);

typedef NS_ERROR_ENUM(CallWaveErrorDomain, CallWaveErrorCode) {
    CallWaveErrorInvalidConfiguration = 1,
    CallWaveErrorEngineAlreadyRunning = 2,
    CallWaveErrorEngineNotRunning = 3,
    CallWaveErrorSIPFailure = 4,
    CallWaveErrorNoActiveCall = 5,
    CallWaveErrorCallActionFailed = 6,
};

typedef NS_ENUM(NSInteger, CallWaveRegistrationState) {
    CallWaveRegistrationStateStopped,
    CallWaveRegistrationStateRegistering,
    CallWaveRegistrationStateRegistered,
    CallWaveRegistrationStateFailed,
};

typedef NS_ENUM(NSInteger, CallWaveCallState) {
    CallWaveCallStateIdle,
    CallWaveCallStateIncoming,
    CallWaveCallStateConnecting,
    CallWaveCallStateActive,
    CallWaveCallStateEnded,
};

@interface CallWaveConfiguration : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *domain;
@property (nonatomic, copy, readonly) NSString *username;
@property (nonatomic, copy, readonly) NSString *password;
@property (nonatomic, assign, readonly) BOOL includesCallsInRecents;

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents NS_DESIGNATED_INITIALIZER;

@end

@class CallWaveClient;

@protocol CallWaveClientDelegate <NSObject>
@optional
- (void)callWaveClient:(CallWaveClient *)client
didChangeRegistrationState:(CallWaveRegistrationState)state
            statusCode:(NSInteger)statusCode;
- (void)callWaveClient:(CallWaveClient *)client
    didReceiveCallFrom:(NSString *)caller
                  uuid:(NSUUID *)uuid;
- (void)callWaveClient:(CallWaveClient *)client
    didChangeCallState:(CallWaveCallState)state
                  uuid:(nullable NSUUID *)uuid;
- (void)callWaveClient:(CallWaveClient *)client
 didUpdateVoIPPushToken:(NSString *)token;
@end

/// Instance-owned SIP/CallKit client.
///
/// PJSUA has a process-global C runtime, so only one client may be running at
/// a time. The client is nevertheless created and injected explicitly; there
/// is no public singleton or service locator.
@interface CallWaveClient : NSObject

@property (nonatomic, strong, readonly) CallWaveConfiguration *configuration;
@property (nonatomic, weak, nullable) id<CallWaveClientDelegate> delegate;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign, readonly, getter=isRegistered) BOOL registered;
@property (nonatomic, assign, readonly, getter=isMicrophoneMuted) BOOL microphoneMuted;
@property (nonatomic, assign, readonly) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readonly) CallWaveCallState callState;
@property (nonatomic, strong, nullable, readonly) NSUUID *currentCallUUID;
@property (nonatomic, copy, nullable, readonly) NSString *currentCaller;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;
- (BOOL)refreshRegistrationWithError:(NSError * _Nullable * _Nullable)error;

- (void)answerWithCompletion:(nullable CallWaveCompletion)completion;
- (void)declineWithCompletion:(nullable CallWaveCompletion)completion;
- (void)hangupWithCompletion:(nullable CallWaveCompletion)completion;
- (void)setMuted:(BOOL)muted completion:(nullable CallWaveCompletion)completion;
- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

- (void)registerForVoIPPushes;
- (void)handleVoIPPushPayload:(NSDictionary *)payload;

@end

NS_ASSUME_NONNULL_END
