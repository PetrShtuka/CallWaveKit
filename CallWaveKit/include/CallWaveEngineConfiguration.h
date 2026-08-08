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
///
/// Quality warnings and the no-media watchdog share this sampler. When this
/// interval is `0` but either of them is enabled, the sampler still runs
/// internally once per second during an active call — it just does not emit
/// `…CallStatisticsUpdated`.
@property (nonatomic, assign) NSTimeInterval statisticsUpdateInterval;

/// Fires `CallWaveEventTypeCallQualityWarning` when inbound loss, jitter or
/// RTT cross the thresholds below. Each warning fires at most once per call.
/// Defaults to YES.
@property (nonatomic, assign) BOOL qualityWarningsEnabled;

/// Inbound loss fraction that raises `CallWaveCallQualityWarningPacketLoss`.
/// Defaults to `0.05` (5 %). Negative values are clamped to `0`.
@property (nonatomic, assign) double qualityWarningPacketLossThreshold;

/// Mean inbound jitter, in seconds, that raises
/// `CallWaveCallQualityWarningHighJitter`. Defaults to `0.03` (30 ms).
@property (nonatomic, assign) NSTimeInterval qualityWarningJitterThreshold;

/// Mean round-trip time, in seconds, that raises
/// `CallWaveCallQualityWarningHighRoundTripTime`. Defaults to `0.3` (300 ms).
@property (nonatomic, assign) NSTimeInterval qualityWarningRoundTripTimeThreshold;

/// Connected seconds without a single inbound RTP packet before
/// `CallWaveCallQualityWarningNoMedia` fires. `0` disables the watchdog.
/// Defaults to `5`.
@property (nonatomic, assign) NSTimeInterval noMediaTimeout;

/// Ends the call through the normal hang-up path when the no-media watchdog
/// fires. Defaults to NO — the host decides whether a silent call is worth
/// killing automatically.
@property (nonatomic, assign) BOOL terminatesCallOnNoMedia;

/// Tags SIP and RTP sockets as voice traffic so routers and iOS itself can
/// prioritise them (DiffServ/service-type tagging, in the spirit of WebRTC
/// SDKs). Defaults to YES.
@property (nonatomic, assign, getter=isQoSTaggingEnabled) BOOL QoSTaggingEnabled;

+ (instancetype)defaultConfiguration NS_SWIFT_NAME(defaultConfiguration());

@end

NS_ASSUME_NONNULL_END
