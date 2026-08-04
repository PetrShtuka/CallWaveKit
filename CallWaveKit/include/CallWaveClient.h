#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>

#import "CallWaveTypes.h"
#import "CallWaveConfiguration.h"
#import "CallWaveEngineConfiguration.h"
#import "CallWaveCallStatistics.h"
#import "CallWaveEvent.h"
#import "CallWaveIncomingCallDescriptor.h"
#import "CallWaveLogging.h"
#import "CallWaveAudioRoute.h"
#import "CallWaveDiagnosticsSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

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
/// The host must remove the invalidated token from its push backend.
- (void)callWaveClientDidInvalidateVoIPPushToken:(CallWaveClient *)client;
/// Sent when the SIP side ends a call. In host-owned CallKit mode without an
/// injected provider this is the host's cue to call
/// `-reportCallWithUUID:endedAtDate:reason:` on its own provider.
- (void)callWaveClient:(CallWaveClient *)client
    didEndCallWithUUID:(NSUUID *)uuid
                reason:(CXCallEndedReason)reason
    NS_SWIFT_NAME(callWaveClient(_:didEndCallWithUUID:reason:));
@end

/// Instance-owned SIP/CallKit client for incoming calls.
///
/// ## Threading
///
/// Every public method may be called from any thread. Internally the client
/// keeps two rules:
///
/// - all of the client's own mutable state changes on the main queue, which is
///   also where the delegate, the event observers and CallKit are driven;
/// - every `pjsua_*` sequence the client initiates runs on one serial queue, so
///   a "read the call info, then act on it" pair cannot interleave with another.
///
/// PJSIP's own callback threads are the documented exception: they talk to
/// PJSUA directly, because a `180 Ringing` that waits for a queue hop is a
/// `180 Ringing` that arrives too late. PJSUA is internally locked, so this is
/// safe; the serial queue exists to serialise CallWaveKit, not PJSUA.
///
/// PJSUA has a process-global C runtime, so only one client may be running at
/// a time. The client is nevertheless created and injected explicitly; there
/// is no public singleton or service locator.
@interface CallWaveClient : NSObject

/// The account the engine is currently configured for, or `nil` before the
/// first `-loginWithConfiguration:completion:`.
@property (nonatomic, strong, readonly, nullable) CallWaveConfiguration *configuration;
/// The runtime settings this client was created with. Immutable once the
/// engine has started.
@property (nonatomic, copy, readonly) CallWaveEngineConfiguration *engineConfiguration;
@property (nonatomic, assign, readonly) CallWaveIntegrationOptions integrationOptions;
/// The provider the library reports through. Library-owned in
/// `CallWaveIntegrationOptionManagesCallKit`, otherwise whatever the host
/// injected (possibly `nil`).
@property (nonatomic, strong, readonly, nullable) CXProvider *provider;
@property (nonatomic, weak, nullable) id<CallWaveClientDelegate> delegate;
/// Convenience for `CallWaveLog.logger`, which is process-wide.
@property (nonatomic, weak, nullable) id<CallWaveLogger> logger;

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign, readonly, getter=isRegistered) BOOL registered;
@property (nonatomic, assign, readonly) CallWaveRegistrationState registrationState;
/// Why the last registration attempt failed, with
/// `CallWaveErrorSIPStatusCodeKey` in `userInfo`. `nil` while registered.
@property (nonatomic, strong, readonly, nullable) NSError *registrationError;

/// State of the most recent call, for hosts that only ever have one.
@property (nonatomic, assign, readonly) CallWaveCallState callState;
@property (nonatomic, strong, nullable, readonly) NSUUID *currentCallUUID;
@property (nonatomic, copy, nullable, readonly) NSString *currentCaller;
/// Microphone state of the most recent call.
@property (nonatomic, assign, readonly, getter=isMicrophoneMuted) BOOL microphoneMuted;
/// Sanitized active route; port types only, never user-visible device names.
@property (nonatomic, strong, readonly) CallWaveAudioRoute *currentAudioRoute;
/// Every call the client is tracking, oldest first.
@property (nonatomic, copy, readonly) NSArray<NSUUID *> *activeCallUUIDs;

/// Shown when a push or an INVITE carries no usable caller. Defaults to
/// `"Unknown"`; a host that wants a localized name sets its own.
@property (nonatomic, copy) NSString *defaultCallerName;

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

/// How long an unanswered incoming call is allowed to ring before the client
/// replies `480 Temporarily Unavailable` and reports it as unanswered.
/// Defaults to 60 seconds; `0` disables the timeout and leaves the call
/// ringing for as long as the PBX keeps it alive.
@property (nonatomic, assign) NSTimeInterval incomingCallTimeout;

/// Hard deadline for the PushKit completion handler passed to
/// `-handleVoIPPushPayload:completion:`. If CallKit has not called back by
/// then the handler runs anyway, because not running it at all terminates the
/// process with `0xBAADCA11`. Defaults to 4 seconds.
@property (nonatomic, assign) NSTimeInterval pushCompletionTimeout;

/// DTMF method used by `-sendDTMF:completion:`. Defaults to
/// `CallWaveDTMFMethodAuto`.
@property (nonatomic, assign) CallWaveDTMFMethod dtmfMethod;

/// Replaces the built-in parsing of `data.uuid` and `data.callerID` in
/// `-handleVoIPPushPayload:completion:`.
@property (nonatomic, copy, nullable) CallWavePushPayloadParser pushPayloadParser;

- (instancetype)init NS_UNAVAILABLE;

/// Library-owned CallKit and PushKit, default engine settings.
- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration;

/// Full control over the two iOS singletons. Pass
/// `CallWaveIntegrationOptionNone` and the host's own `CXProvider` for a host
/// that already owns CallKit and PushKit; pass a `nil` configuration when
/// credentials only arrive with the first push.
- (instancetype)initWithConfiguration:(nullable CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(nullable CXProvider *)provider;

/// Full control, including the PJSUA runtime settings. `nil` engine
/// configuration means `+[CallWaveEngineConfiguration defaultConfiguration]`.
- (instancetype)initWithConfiguration:(nullable CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(nullable CXProvider *)provider
                  engineConfiguration:(nullable CallWaveEngineConfiguration *)engineConfiguration
    NS_DESIGNATED_INITIALIZER;

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

/// Rebuilds transports and re-registers after a network change. The client
/// does this on its own unless `handlesNetworkChanges` was turned off.
- (void)handleNetworkChange;

#pragma mark - Call control through CallKit

- (void)answerWithCompletion:(nullable CallWaveCompletion)completion;
- (void)declineWithCompletion:(nullable CallWaveCompletion)completion;
- (void)hangupWithCompletion:(nullable CallWaveCompletion)completion;
- (void)setMuted:(BOOL)muted completion:(nullable CallWaveCompletion)completion;
/// Requests a `CXSetHeldCallAction`. Only available when
/// `engineConfiguration.maximumCalls` is greater than 1.
- (void)setHeld:(BOOL)held completion:(nullable CallWaveCompletion)completion;
- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

#pragma mark - Direct call control

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
- (void)setMicrophoneMuted:(BOOL)muted
           forCallWithUUID:(nullable NSUUID *)uuid
                completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(setMicrophoneMuted(_:forCallWithUUID:completion:));

/// Puts a SIP call on hold with a re-INVITE, without a CallKit transaction.
- (void)setHeld:(BOOL)held
forCallWithUUID:(nullable NSUUID *)uuid
     completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(setHeld(_:forCallWithUUID:completion:));

#pragma mark - Call information

- (CallWaveCallState)stateForCallWithUUID:(NSUUID *)uuid
    NS_SWIFT_NAME(state(forCallWithUUID:));
- (nullable NSString *)callerForCallWithUUID:(NSUUID *)uuid
    NS_SWIFT_NAME(caller(forCallWithUUID:));
/// RTP/RTCP counters for the call's audio stream, or `nil` when there is no
/// media yet. Pass `nil` for the current call.
- (nullable CallWaveCallStatistics *)statisticsForCallWithUUID:(nullable NSUUID *)uuid
    NS_SWIFT_NAME(statistics(forCallWithUUID:));

/// Credential-free runtime state suitable for a support attachment.
- (CallWaveDiagnosticsSnapshot *)diagnosticsSnapshot;

/// The lock-screen name CallWaveKit would derive from a raw SIP `From` value:
/// the quoted display name, else the user part, else the value itself.
+ (NSString *)displayNameForCaller:(nullable NSString *)caller
    NS_SWIFT_NAME(displayName(forCaller:));

/// `digits` with everything that is not `0-9`, `A-D`, `*` or `#` removed, and
/// the remainder upper-cased. An empty result means nothing was sendable.
+ (NSString *)normalizedDTMFDigits:(nullable NSString *)digits
    NS_SWIFT_NAME(normalizedDTMFDigits(_:));

#pragma mark - DTMF

/// Sends `digits` (`0-9`, `A-D`, `*`, `#`) on the active call using
/// `dtmfMethod`. This is how intercom doors are opened.
- (void)sendDTMF:(NSString *)digits completion:(nullable CallWaveCompletion)completion;
- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
      completion:(nullable CallWaveCompletion)completion;
- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
 forCallWithUUID:(nullable NSUUID *)uuid
      completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(sendDTMF(_:method:forCallWithUUID:completion:));

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

/// Handles a server push that retracts an earlier incoming-call push. It
/// closes a pending CallKit screen, prevents a late INVITE from ringing again
/// and is idempotent when the call is already gone.
- (void)handleCancelledIncomingCallWithUUID:(NSUUID *)uuid
                                      reason:(CXCallEndedReason)reason
                                  completion:(nullable CallWaveCompletion)completion
    NS_SWIFT_NAME(handleCancelledIncomingCall(uuid:reason:completion:));

#pragma mark - PushKit

/// No-op unless `CallWaveIntegrationOptionManagesVoIPPushRegistry` is set.
- (void)registerForVoIPPushes;

/// Parses `payload` with `pushPayloadParser`, or with the built-in
/// `data.uuid` / `data.callerID` reader, reports the call and calls
/// `completion` once CallKit has accepted the report — or after
/// `pushCompletionTimeout`, whichever comes first. Failing to run the handler
/// is what produces the `0xBAADCA11` termination and the VoIP push ban.
- (void)handleVoIPPushPayload:(NSDictionary *)payload
                   completion:(nullable void (^)(void))completion;

- (void)handleVoIPPushPayload:(NSDictionary *)payload
    __attribute__((deprecated("Use -handleVoIPPushPayload:completion: and pass the PushKit completion handler.")));

#pragma mark - Events

/// Registers `handler` for every `CallWaveEvent`, on the main queue. The
/// returned token must be kept and passed to `-removeEventObserver:`;
/// the client holds `handler` until then.
- (id<NSCopying, NSObject>)addEventObserver:(void (^)(CallWaveEvent *event))handler
    NS_SWIFT_NAME(addEventObserver(_:));
- (void)removeEventObserver:(id<NSCopying, NSObject>)token;

@end

NS_ASSUME_NONNULL_END
