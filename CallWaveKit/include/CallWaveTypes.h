#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const CallWaveErrorDomain;

/// `NSNumber` holding the SIP status code (`403`, `408`, `486`, …) when the
/// failure was reported by the network. Absent for purely local failures.
FOUNDATION_EXPORT NSErrorUserInfoKey const CallWaveErrorSIPStatusCodeKey;
/// `NSNumber` holding the raw `pj_status_t` PJSIP returned.
FOUNDATION_EXPORT NSErrorUserInfoKey const CallWaveErrorPJStatusKey;
/// `NSString` naming the operation that failed, e.g. `"SIP account setup"`.
FOUNDATION_EXPORT NSErrorUserInfoKey const CallWaveErrorOperationKey;

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
    /// A further call would exceed `CallWaveEngineConfiguration.maximumCalls`.
    CallWaveErrorCallLimitReached = 11,
    /// The action is not supported in the current integration mode or by the
    /// current engine configuration.
    CallWaveErrorUnsupportedOperation = 12,
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
    /// The call is established but the local side has put it on hold.
    CallWaveCallStateHeld,
    CallWaveCallStateEnded,
};

/// SIP signalling transport. The registrar URI carries the matching
/// `transport=` parameter; the identity URI never carries a port or transport.
typedef NS_ENUM(NSInteger, CallWaveTransport) {
    CallWaveTransportUDP = 0,
    CallWaveTransportTCP,
    CallWaveTransportTLS,
};

/// Address-family policy for SIP signalling and RTP media.
typedef NS_ENUM(NSInteger, CallWaveIPVersionPolicy) {
    /// Prefer the address family available on the current network and allow
    /// both IPv4 and IPv6. This is the default and supports IPv6-only/NAT64.
    CallWaveIPVersionPolicyAutomatic = 0,
    /// Compatibility mode for older intercom PBXs that only listen on IPv4.
    CallWaveIPVersionPolicyIPv4Only,
    /// Require IPv6 signalling and media.
    CallWaveIPVersionPolicyIPv6Only,
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

/// SRTP policy for the account's media.
typedef NS_ENUM(NSInteger, CallWaveMediaEncryption) {
    /// Plain RTP only. The historical behaviour and the default.
    CallWaveMediaEncryptionDisabled = 0,
    /// Offer SRTP, accept plain RTP when the peer cannot do better.
    CallWaveMediaEncryptionOptional,
    /// Require SRTP; a peer that will not encrypt fails the call.
    CallWaveMediaEncryptionMandatory,
};

/// Verbosity of both CallWaveKit's own log and the PJSIP log it forwards.
typedef NS_ENUM(NSInteger, CallWaveLogLevel) {
    CallWaveLogLevelOff = 0,
    CallWaveLogLevelError,
    CallWaveLogLevelWarning,
    CallWaveLogLevelInfo,
    /// Includes the PJSIP protocol trace. `Authorization` header values are
    /// scrubbed while `CallWaveLog.redactsIdentifiers` is on, but this level
    /// still dumps whole SIP messages, so it must not ship in a release build.
    CallWaveLogLevelDebug,
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

NS_ASSUME_NONNULL_END
