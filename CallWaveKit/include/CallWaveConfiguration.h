#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

// `NS_SWIFT_SENDABLE` arrived with the Xcode 15 SDK; older SDKs simply lose the
// annotation, which costs Swift concurrency checking and nothing else.
#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

@class CallWaveConfiguration;

/// Mutable staging area for `CallWaveConfiguration`. Every property that is not
/// set keeps the default documented on the immutable class.
@interface CallWaveConfigurationBuilder : NSObject

/// Registrar host without port, e.g. `sip.example.com` or `10.0.0.5`.
@property (nonatomic, copy) NSString *host;
/// Registrar port. `0` means the transport default (5060, or 5061 for TLS).
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) CallWaveTransport transport;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, assign) BOOL includesCallsInRecents;

/// Digest authentication user when it differs from the SIP user. `nil` reuses
/// `username`.
@property (nonatomic, copy, nullable) NSString *authenticationUsername;
/// Digest realm. `nil` means `*`, which matches whatever the registrar sends.
@property (nonatomic, copy, nullable) NSString *realm;
/// Full SIP URI of an outbound proxy, e.g. `sip:proxy.example.com;transport=tcp`.
@property (nonatomic, copy, nullable) NSString *outboundProxy;
/// Requested `Expires` for REGISTER, in seconds. `0` means 300.
@property (nonatomic, assign) NSUInteger registrationExpiry;
/// SIP keep-alive interval in seconds. `0` means 15, which is what keeps a NAT
/// binding open for an intercom that calls once a week.
@property (nonatomic, assign) NSUInteger keepAliveInterval;
@property (nonatomic, assign) CallWaveMediaEncryption mediaEncryption;
/// Session timers (RFC 4028) policy for calls on this account.
@property (nonatomic, assign) CallWaveSessionTimersMode sessionTimersMode;
/// Requested `Session-Expires` in seconds. `0` means 1800, the value RFC 4028
/// recommends.
@property (nonatomic, assign) NSUInteger sessionTimerInterval;
/// Requested `Min-SE` in seconds. `0` means 90; smaller non-zero values are
/// clamped to 90 because RFC 4028 forbids a lower absolute minimum.
@property (nonatomic, assign) NSUInteger sessionTimerMinimum;
/// Extra headers added to REGISTER, e.g. a tenant identifier. Header names are
/// used verbatim.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *additionalRegistrationHeaders;

@end

/// Immutable SIP account description.
///
/// Hosts that receive credentials inside every VoIP push build a fresh
/// configuration per call and hand it to `-loginWithConfiguration:completion:`;
/// the PJSUA stack is not recreated.
NS_SWIFT_SENDABLE
@interface CallWaveConfiguration : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, assign, readonly) NSUInteger port;
@property (nonatomic, assign, readonly) CallWaveTransport transport;
@property (nonatomic, copy, readonly) NSString *username;
@property (nonatomic, copy, readonly) NSString *password;
@property (nonatomic, assign, readonly) BOOL includesCallsInRecents;

/// `username` unless a separate digest user was configured.
@property (nonatomic, copy, readonly) NSString *authenticationUsername;
/// `*` unless a realm was configured.
@property (nonatomic, copy, readonly) NSString *realm;
@property (nonatomic, copy, readonly, nullable) NSString *outboundProxy;
/// Defaults to `300`.
@property (nonatomic, assign, readonly) NSUInteger registrationExpiry;
/// Defaults to `15`.
@property (nonatomic, assign, readonly) NSUInteger keepAliveInterval;
/// Defaults to `CallWaveMediaEncryptionDisabled`.
@property (nonatomic, assign, readonly) CallWaveMediaEncryption mediaEncryption;
/// Defaults to `CallWaveSessionTimersModeOptional`.
@property (nonatomic, assign, readonly) CallWaveSessionTimersMode sessionTimersMode;
/// Defaults to `1800`.
@property (nonatomic, assign, readonly) NSUInteger sessionTimerInterval;
/// Defaults to `90`, the smallest value RFC 4028 allows.
@property (nonatomic, assign, readonly) NSUInteger sessionTimerMinimum;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *additionalRegistrationHeaders;

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
      includesCallsInRecents:(BOOL)includesCallsInRecents;

/// Splits `host:port` and defaults to UDP.
- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents;

/// The full surface, including the optional account settings.
///
/// ```swift
/// let configuration = CallWaveConfiguration { builder in
///     builder.host = "sip.example.com"
///     builder.username = "1001"
///     builder.password = password
///     builder.transport = .TLS
///     builder.mediaEncryption = .mandatory
/// }
/// ```
- (instancetype)initWithBuilder:(NS_NOESCAPE void (^)(CallWaveConfigurationBuilder *builder))block
    NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(_:));

/// A copy with `block` applied on top, for changing one field of an existing
/// account description.
- (instancetype)configurationByApplying:(NS_NOESCAPE void (^)(CallWaveConfigurationBuilder *builder))block
    NS_SWIFT_NAME(applying(_:));

/// YES when both descriptions address the same account with the same
/// credentials and the same account-level settings, so re-registering is enough
/// and the account need not be replaced.
- (BOOL)isEqualToConfiguration:(nullable CallWaveConfiguration *)other;

@end

NS_ASSUME_NONNULL_END
