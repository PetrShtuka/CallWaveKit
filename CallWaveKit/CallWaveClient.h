#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>

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
    CallWaveErrorNotConfigured = 7,
    CallWaveErrorTimedOut = 8,
    CallWaveErrorInvalidArgument = 9,
    CallWaveErrorAudioSessionFailure = 10,
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

/// SIP signalling transport. The registrar URI carries the matching
/// `transport=` parameter; the identity URI never carries a port or transport.
typedef NS_ENUM(NSInteger, CallWaveTransport) {
    CallWaveTransportUDP = 0,
    CallWaveTransportTCP,
    CallWaveTransportTLS,
};

/// How DTMF digits leave the device.
typedef NS_ENUM(NSInteger, CallWaveDTMFMethod) {
    /// RFC 2833 telephone-event in the RTP stream, falling back to SIP INFO
    /// when the peer did not negotiate telephone-event. This is the default and
    /// what intercom door-openers expect.
    CallWaveDTMFMethodAuto = 0,
    CallWaveDTMFMethodRFC2833,
    CallWaveDTMFMethodSIPINFO,
};

/// Which of the two process-global iOS singletons the client is allowed to own.
///
/// A host that already runs its own `CXProvider` (branded icon, localized name)
/// or its own `PKPushRegistry` must not let the library create a second one:
/// two `.voIP` registries or two providers in one process desynchronise call
/// state. Clear the corresponding option and drive the library through
/// `-prepareIncomingCallWithUUID:caller:`, `-acceptCallWithUUID:…`,
/// `-endCallWithUUID:completion:` and the audio-session hooks instead.
typedef NS_OPTIONS(NSUInteger, CallWaveIntegrationOptions) {
    CallWaveIntegrationOptionNone = 0,
    /// The library creates a `CXProvider`, becomes its delegate and reports
    /// incoming calls itself.
    CallWaveIntegrationOptionManagesCallKit = 1 << 0,
    /// The library creates a `PKPushRegistry` for `PKPushTypeVoIP`.
    CallWaveIntegrationOptionManagesVoIPPushRegistry = 1 << 1,
    /// What `-initWithConfiguration:` uses.
    CallWaveIntegrationOptionManagesEverything =
        CallWaveIntegrationOptionManagesCallKit |
        CallWaveIntegrationOptionManagesVoIPPushRegistry,
};

/// Immutable SIP account description.
///
/// Hosts that receive credentials inside every VoIP push build a fresh
/// configuration per call and hand it to `-loginWithConfiguration:completion:`;
/// the PJSUA stack is not recreated.
@interface CallWaveConfiguration : NSObject <NSCopying>

/// Registrar host without port, e.g. `sip.example.com` or `10.0.0.5`.
@property (nonatomic, copy, readonly) NSString *host;
/// Registrar port. `0` means the transport default (5060, or 5061 for TLS).
@property (nonatomic, assign, readonly) NSUInteger port;
@property (nonatomic, assign, readonly) CallWaveTransport transport;
@property (nonatomic, copy, readonly) NSString *username;
@property (nonatomic, copy, readonly) NSString *password;
@property (nonatomic, assign, readonly) BOOL includesCallsInRecents;

/// `host` or `host:port`. Retained for callers written against the previous
/// single-string API.
@property (nonatomic, copy, readonly) NSString *domain;
/// `sip:username@host` — no port, no transport parameter.
@property (nonatomic, copy, readonly) NSString *identityURI;
/// `sip:host:port` plus `;transport=` for TCP and TLS.
@property (nonatomic, copy, readonly) NSString *registrarURI;

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithHost:(NSString *)host
                        port:(NSUInteger)port
                   transport:(CallWaveTransport)transport
                    username:(NSString *)username
                    password:(NSString *)password
      includesCallsInRecents:(BOOL)includesCallsInRecents NS_DESIGNATED_INITIALIZER;

/// Splits `host:port` and defaults to UDP.
- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents;

/// YES when both descriptions address the same account with the same
/// credentials, so re-registering is enough and the account need not be
/// replaced.
- (BOOL)isEqualToConfiguration:(nullable CallWaveConfiguration *)other;

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
/// Sent when the SIP side ends a call. In host-owned CallKit mode without an
/// injected provider this is the host's cue to call
/// `-reportCallWithUUID:endedAtDate:reason:` on its own provider.
- (void)callWaveClient:(CallWaveClient *)client
    didEndCallWithUUID:(NSUUID *)uuid
                reason:(CXCallEndedReason)reason
    NS_SWIFT_NAME(callWaveClient(_:didEndCallWithUUID:reason:));
@end

/// Instance-owned SIP/CallKit client.
///
/// PJSUA has a process-global C runtime, so only one client may be running at
/// a time. The client is nevertheless created and injected explicitly; there
/// is no public singleton or service locator.
@interface CallWaveClient : NSObject

/// The account the engine is currently configured for, or `nil` before the
/// first `-loginWithConfiguration:completion:`.
@property (nonatomic, strong, readonly, nullable) CallWaveConfiguration *configuration;
@property (nonatomic, assign, readonly) CallWaveIntegrationOptions integrationOptions;
/// The provider the library reports through. Library-owned in
/// `CallWaveIntegrationOptionManagesCallKit`, otherwise whatever the host
/// injected (possibly `nil`).
@property (nonatomic, strong, readonly, nullable) CXProvider *provider;
@property (nonatomic, weak, nullable) id<CallWaveClientDelegate> delegate;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign, readonly, getter=isRegistered) BOOL registered;
@property (nonatomic, assign, readonly, getter=isMicrophoneMuted) BOOL microphoneMuted;
@property (nonatomic, assign, readonly) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readonly) CallWaveCallState callState;
@property (nonatomic, strong, nullable, readonly) NSUUID *currentCallUUID;
@property (nonatomic, copy, nullable, readonly) NSString *currentCaller;

/// How long the client waits for the INVITE of a call that CallKit has already
/// answered. Defaults to 10 seconds. The CallKit action itself is fulfilled
/// immediately, so this may safely exceed CallKit's own action timeout.
@property (nonatomic, assign) NSTimeInterval answerTimeout;

/// Pause between spotting the INVITE and sending `200 OK`. Intercom PBXs are
/// not always ready to accept the answer the moment they have sent the INVITE,
/// and answering too early tears the call down.
///
/// Defaults to 0.5 seconds, which is the value the previous linphone-based
/// implementation used. Values are clamped to `[0, 1.0]`: CallKit already shows
/// the call as connected while this pause runs, so anything past a second reads
/// to the user as a call that does not work.
///
/// The pause is applied once per call, only after the INVITE has been found. It
/// is not part of `answerTimeout`.
@property (nonatomic, assign) NSTimeInterval acceptDelay;

/// DTMF method used by `-sendDTMF:completion:`. Defaults to
/// `CallWaveDTMFMethodAuto`.
@property (nonatomic, assign) CallWaveDTMFMethod dtmfMethod;

- (instancetype)init NS_UNAVAILABLE;

/// Library-owned CallKit and PushKit.
- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration;

/// Full control. Pass `CallWaveIntegrationOptionNone` and the host's own
/// `CXProvider` for a host that already owns CallKit and PushKit; pass a `nil`
/// configuration when credentials only arrive with the first push.
- (instancetype)initWithConfiguration:(nullable CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(nullable CXProvider *)provider NS_DESIGNATED_INITIALIZER;

#pragma mark - Engine and account lifecycle

/// Starts the PJSUA stack and registers `configuration`.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;

/// Starts the PJSUA stack without an account. Use this at launch when
/// credentials are not known yet, then call `-loginWithConfiguration:completion:`.
- (BOOL)startEngineWithError:(NSError * _Nullable * _Nullable)error;

/// Replaces the SIP account and registers it, starting the stack if needed.
/// The PJSUA runtime is *not* destroyed, so this is safe to call from a VoIP
/// push on every call. Identical configurations only refresh the registration.
- (void)loginWithConfiguration:(CallWaveConfiguration *)configuration
                    completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(login(configuration:completion:));

/// Synchronous form of `-loginWithConfiguration:completion:`.
- (BOOL)updateConfiguration:(CallWaveConfiguration *)configuration
                      error:(NSError * _Nullable * _Nullable)error;

- (BOOL)refreshRegistrationWithError:(NSError * _Nullable * _Nullable)error;

/// Sends `REGISTER` with `Expires: 0` and keeps both the account and the stack
/// alive, ready for the next `-refreshRegistrationWithError:`.
- (BOOL)unregisterWithError:(NSError * _Nullable * _Nullable)error;

/// Unregisters and deletes the account but keeps the PJSUA stack running.
- (BOOL)logoutWithError:(NSError * _Nullable * _Nullable)error;

/// Tears the PJSUA runtime down entirely (`pjsua_destroy`). Prefer
/// `-unregisterWithError:` or `-logoutWithError:` between calls.
- (void)stop;

#pragma mark - Call control

- (void)answerWithCompletion:(nullable CallWaveCompletion)completion;
- (void)declineWithCompletion:(nullable CallWaveCompletion)completion;
- (void)hangupWithCompletion:(nullable CallWaveCompletion)completion;
- (void)setMuted:(BOOL)muted completion:(nullable CallWaveCompletion)completion;
- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

/// Answers the SIP call directly, without going through `CXCallController`.
/// If the INVITE has not arrived yet the client polls until `answerTimeout`
/// elapses — the host is expected to have fulfilled the CallKit action already.
/// Once the call is found, the answer waits out `acceptDelay`. Pass `nil` for
/// the current call.
- (void)acceptCallWithUUID:(nullable NSUUID *)uuid
                completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(acceptCall(uuid:completion:));
- (void)acceptCallWithUUID:(nullable NSUUID *)uuid
                   timeout:(NSTimeInterval)timeout
                completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(acceptCall(uuid:timeout:completion:));

/// Hangs the SIP call up directly, without a CallKit transaction.
- (void)endCallWithUUID:(nullable NSUUID *)uuid
             completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(endCall(uuid:completion:));

/// Rejects a still-ringing SIP call with `603 Decline`.
- (void)declineCallWithUUID:(nullable NSUUID *)uuid
                 completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(declineCall(uuid:completion:));

/// Applies an RTP-level microphone mute without a CallKit transaction.
- (BOOL)setMicrophoneMuted:(BOOL)muted error:(NSError * _Nullable * _Nullable)error;

#pragma mark - DTMF

/// Sends `digits` (`0-9`, `A-D`, `*`, `#`) on the active call using
/// `dtmfMethod`. This is how intercom doors are opened.
- (void)sendDTMF:(NSString *)digits completion:(nullable CallWaveCompletion)completion;
- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
      completion:(nullable CallWaveCompletion)completion;

#pragma mark - Audio session

/// Applies the `playAndRecord`/`voiceChat` category without activating the
/// session. Call this before answering, as CallKit expects the category to be
/// in place when it activates the session.
- (BOOL)configureAudioSessionWithError:(NSError * _Nullable * _Nullable)error;

/// Activates the audio session and opens the PJSIP sound device. Use this as
/// the fallback when `-provider:didActivateAudioSession:` does not arrive.
- (BOOL)activateAudioSessionWithError:(NSError * _Nullable * _Nullable)error;

/// Forward from the host's `-provider:didActivateAudioSession:`.
- (void)audioSessionDidActivate:(AVAudioSession *)audioSession;
/// Forward from the host's `-provider:didDeactivateAudioSession:`.
- (void)audioSessionDidDeactivate:(AVAudioSession *)audioSession;

#pragma mark - Incoming calls

/// Binds a call UUID the host already reported to CallKit, so the INVITE that
/// follows is matched to it instead of producing a second CallKit call. Also
/// nudges the SIP registration. Use this in host-owned CallKit mode.
- (void)prepareIncomingCallWithUUID:(NSUUID *)uuid
                             caller:(nullable NSString *)caller
    NS_SWIFT_NAME(prepareIncomingCall(uuid:caller:));

/// Reports an incoming call with an explicit UUID and caller, without parsing
/// any push payload. `completion` runs inside the
/// `-reportNewIncomingCallWithUUID:update:completion:` completion block, which
/// is where a PushKit completion handler must be invoked.
- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(nullable NSString *)caller
                        completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(reportIncomingCall(uuid:caller:completion:));

#pragma mark - PushKit

/// No-op unless `CallWaveIntegrationOptionManagesVoIPPushRegistry` is set.
- (void)registerForVoIPPushes;

/// Parses `payload` (`data.uuid` / `data.callerID`), reports the call and calls
/// `completion` only once CallKit has accepted the report. Failing to sequence
/// these is what produces the `0xBAADCA11` termination and the VoIP push ban.
- (void)handleVoIPPushPayload:(NSDictionary *)payload
                   completion:(nullable void (^)(void))completion;

- (void)handleVoIPPushPayload:(NSDictionary *)payload
    __attribute__((deprecated("Use -handleVoIPPushPayload:completion: and pass the PushKit completion handler.")));

@end

NS_ASSUME_NONNULL_END
