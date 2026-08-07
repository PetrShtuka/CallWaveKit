#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Receives every line CallWaveKit and PJSIP emit, so a host can route them
/// into its own logging stack. Called on an arbitrary thread, including PJSIP's
/// own worker threads — do not block.
@protocol CallWaveLogger <NSObject>
- (void)callWaveDidLogMessage:(NSString *)message
                        level:(CallWaveLogLevel)level
                     category:(NSString *)category;
@end

/// Process-wide logging configuration.
///
/// PJSIP's log is a process-global C facility, so this configuration is global
/// too rather than per-client. `CallWaveClient` mirrors `level` from its engine
/// configuration when it starts.
@interface CallWaveLog : NSObject

/// Defaults to `CallWaveLogLevelWarning`, or `CallWaveLogLevelInfo` when the
/// library itself was compiled with `DEBUG`.
@property (class, nonatomic, assign) CallWaveLogLevel level;

/// Optional host sink. Messages always also go to `os_log`.
@property (class, nonatomic, weak, nullable) id<CallWaveLogger> logger;

/// When YES — the default — SIP URIs, caller identifiers, DTMF digits and
/// registrar hosts are replaced with `<private>` before a message is formatted,
/// and `Authorization`/`Proxy-Authorization` values in the PJSIP trace are
/// scrubbed. Turn it off only in a build you control, never in a shipped
/// application: with redaction disabled the debug trace is fully raw.
@property (class, nonatomic, assign, getter=isRedactingIdentifiers) BOOL redactsIdentifiers;

/// `value` itself, or `@"<private>"` when redaction is on. Use this for every
/// identifier that reaches a log line.
+ (NSString *)redact:(nullable NSString *)value;

+ (void)logLevel:(CallWaveLogLevel)level
        category:(NSString *)category
          format:(NSString *)format, ... NS_FORMAT_FUNCTION(3, 4);

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
