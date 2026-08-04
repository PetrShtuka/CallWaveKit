#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class CallWaveTURNConfiguration;

/// Settings that belong to the PJSUA runtime rather than to a SIP account.
///
/// The runtime is process-global and is configured once, when the first
/// `-startEngineWithError:` succeeds. Changing an instance afterwards has no
/// effect until the runtime is destroyed with `-stop` and started again.
@interface CallWaveEngineConfiguration : NSObject <NSCopying>

/// How many simultaneous calls the stack accepts. `1` — the default — makes a
/// second INVITE answer `486 Busy Here`, which is what an intercom expects.
/// Values above 1 enable call waiting and CallKit hold.
@property (nonatomic, assign) NSUInteger maximumCalls;

/// Mirrored into `CallWaveLog.level` when the engine starts. Defaults to
/// `CallWaveLogLevelWarning`.
@property (nonatomic, assign) CallWaveLogLevel logLevel;

/// `User-Agent` header. `nil` uses PJSIP's own.
@property (nonatomic, copy, nullable) NSString *userAgent;

/// Defaults to NO. Intercoms are usually on the same LAN, and ICE adds a
/// gathering round-trip to every call.
@property (nonatomic, assign, getter=isICEEnabled) BOOL ICEEnabled;

/// `host` or `host:port` entries, e.g. `@[@"stun.example.com:3478"]`.
@property (nonatomic, copy) NSArray<NSString *> *STUNServers;

/// Optional TURN relay used by ICE when direct media paths fail. Setting this
/// automatically enables ICE. Credentials are never logged.
@property (nonatomic, copy, nullable) CallWaveTURNConfiguration *TURNConfiguration;

/// SIP and media address-family policy. Defaults to automatic.
@property (nonatomic, assign) CallWaveIPVersionPolicy IPVersionPolicy;

/// Codec identifiers in descending priority, e.g.
/// `@[@"PCMA/8000", @"PCMU/8000", @"opus/48000"]`. Codecs that are not listed
/// keep a lower priority but stay enabled. An empty array — the default —
/// leaves PJSIP's own ordering alone.
@property (nonatomic, copy) NSArray<NSString *> *preferredCodecs;

/// Verifies the registrar's certificate on TLS transports. Defaults to YES.
/// An intercom with a self-signed certificate needs this turned off, and that
/// is a deliberate decision to make in the host, not a default.
@property (nonatomic, assign) BOOL verifiesTLSCertificate;

/// Acoustic echo cancellation tail length in milliseconds. `0` disables the
/// canceller. Defaults to 200.
@property (nonatomic, assign) NSUInteger echoCancellationTailMilliseconds;

/// Silence suppression. Defaults to NO — an intercom that hears nothing during
/// a pause reads as a dead call.
@property (nonatomic, assign, getter=isVoiceActivityDetectionEnabled) BOOL voiceActivityDetectionEnabled;

/// Re-registers and rebuilds transports when the device changes network, which
/// is what keeps an intercom reachable across a Wi-Fi to cellular handover.
/// Defaults to YES.
@property (nonatomic, assign) BOOL handlesNetworkChanges;

/// Interval for `CallWaveEventTypeCallStatisticsUpdated`, in seconds. `0` —
/// the default — disables periodic sampling. Values below one second are
/// clamped to one to avoid wasting battery.
@property (nonatomic, assign) NSTimeInterval statisticsUpdateInterval;

+ (instancetype)defaultConfiguration NS_SWIFT_NAME(defaultConfiguration());

@end

NS_ASSUME_NONNULL_END
