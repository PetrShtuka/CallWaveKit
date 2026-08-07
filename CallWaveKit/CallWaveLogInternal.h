#import "CallWaveLogging.h"

// The parameters are prefixed because the macro body names the `category:` and
// `format:` selector parts, and an unprefixed parameter would be substituted
// into the selector as well.
#define CWLogError(cwCategory, cwFormat, ...) \
    [CallWaveLog logLevel:CallWaveLogLevelError category:(cwCategory) format:(cwFormat), ##__VA_ARGS__]
#define CWLogWarning(cwCategory, cwFormat, ...) \
    [CallWaveLog logLevel:CallWaveLogLevelWarning category:(cwCategory) format:(cwFormat), ##__VA_ARGS__]
#define CWLogInfo(cwCategory, cwFormat, ...) \
    [CallWaveLog logLevel:CallWaveLogLevelInfo category:(cwCategory) format:(cwFormat), ##__VA_ARGS__]
#define CWLogDebug(cwCategory, cwFormat, ...) \
    [CallWaveLog logLevel:CallWaveLogLevelDebug category:(cwCategory) format:(cwFormat), ##__VA_ARGS__]

#define CWRedact(cwValue) [CallWaveLog redact:(cwValue)]

@interface CallWaveLog (CredentialScrubbing)
/// Scrubs `Authorization:`/`Proxy-Authorization:` values from a PJSIP trace
/// message. Internal: applied by the PJSIP log sink before forwarding.
+ (NSString *)scrubAuthorizationInMessage:(NSString *)message;
@end

// Macros rather than file-static constants so a translation unit that uses only
// some of them does not warn about the rest.
#define CallWaveLogCategorySIP     @"sip"
#define CallWaveLogCategoryCall    @"call"
#define CallWaveLogCategoryAudio   @"audio"
#define CallWaveLogCategoryPush    @"push"
#define CallWaveLogCategoryNetwork @"network"
#define CallWaveLogCategoryPJSIP   @"pjsip"
