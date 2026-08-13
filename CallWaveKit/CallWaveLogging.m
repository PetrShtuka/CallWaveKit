#import "CallWaveLogging.h"

#import <os/lock.h>
#import <os/log.h>

static CallWaveLogLevel gLevel =
#if DEBUG
    CallWaveLogLevelInfo;
#else
    CallWaveLogLevelWarning;
#endif
static __weak id<CallWaveLogger> gLogger = nil;
static BOOL gRedacts = YES;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static os_log_t CallWaveOSLog(NSString *category) {
    static NSMutableDictionary<NSString *, id> *logs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logs = [NSMutableDictionary dictionary];
    });

    os_unfair_lock_lock(&gLock);
    os_log_t log = (os_log_t)logs[category];
    if (log == nil) {
        log = os_log_create("com.callwave.kit", category.UTF8String);
        logs[category] = log;
    }
    os_unfair_lock_unlock(&gLock);
    return log;
}

static os_log_type_t CallWaveOSLogType(CallWaveLogLevel level) {
    switch (level) {
        case CallWaveLogLevelOff:     return OS_LOG_TYPE_DEBUG;
        case CallWaveLogLevelError:   return OS_LOG_TYPE_ERROR;
        case CallWaveLogLevelWarning: return OS_LOG_TYPE_DEFAULT;
        case CallWaveLogLevelInfo:    return OS_LOG_TYPE_INFO;
        case CallWaveLogLevelDebug:   return OS_LOG_TYPE_DEBUG;
    }
    return OS_LOG_TYPE_DEFAULT;
}

@implementation CallWaveLog

+ (CallWaveLogLevel)level {
    os_unfair_lock_lock(&gLock);
    CallWaveLogLevel level = gLevel;
    os_unfair_lock_unlock(&gLock);
    return level;
}

+ (void)setLevel:(CallWaveLogLevel)level {
    os_unfair_lock_lock(&gLock);
    gLevel = level;
    os_unfair_lock_unlock(&gLock);
}

+ (id<CallWaveLogger>)logger {
    os_unfair_lock_lock(&gLock);
    id<CallWaveLogger> logger = gLogger;
    os_unfair_lock_unlock(&gLock);
    return logger;
}

+ (void)setLogger:(id<CallWaveLogger>)logger {
    os_unfair_lock_lock(&gLock);
    gLogger = logger;
    os_unfair_lock_unlock(&gLock);
}

+ (BOOL)isRedactingIdentifiers {
    os_unfair_lock_lock(&gLock);
    BOOL redacts = gRedacts;
    os_unfair_lock_unlock(&gLock);
    return redacts;
}

+ (void)setRedactsIdentifiers:(BOOL)redactsIdentifiers {
    os_unfair_lock_lock(&gLock);
    gRedacts = redactsIdentifiers;
    os_unfair_lock_unlock(&gLock);
}

+ (NSString *)redact:(NSString *)value {
    if (value.length == 0) {
        return @"";
    }
    return CallWaveLog.isRedactingIdentifiers ? @"<private>" : value;
}

/// Replaces the value of every `Authorization:` / `Proxy-Authorization:` line
/// with `<redacted>`, keeping the header name for readability. Credentials are
/// always removed; `redactsIdentifiers` only controls identifiers such as
/// callers, UUIDs and addresses. Folded continuation lines belonging to an
/// authorization header are removed as well.
+ (NSString *)scrubAuthorizationInMessage:(NSString *)message {
    if ([message rangeOfString:@"uthorization:"
                       options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return message;
    }

    NSMutableString *scrubbed = [NSMutableString stringWithCapacity:message.length];
    __block BOOL scrubbingContinuation = NO;
    [message enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        BOOL continuation = [line hasPrefix:@" "] || [line hasPrefix:@"\t"];
        if (scrubbingContinuation && continuation) {
            return;
        }
        scrubbingContinuation = NO;

        NSRange colon = [line rangeOfString:@":"];
        NSString *name = colon.location == NSNotFound ? @""
            : [[line substringToIndex:colon.location]
               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        BOOL sensitive = [name caseInsensitiveCompare:@"Authorization"] == NSOrderedSame ||
                         [name caseInsensitiveCompare:@"Proxy-Authorization"] == NSOrderedSame;
        if (sensitive) {
            [scrubbed appendFormat:@"%@: <redacted>\n", name];
            scrubbingContinuation = YES;
        } else {
            [scrubbed appendString:line];
            [scrubbed appendString:@"\n"];
        }
    }];

    // `enumerateLinesUsingBlock` drops the information about a missing final
    // newline; restore the original shape.
    if (![message hasSuffix:@"\n"] && ![message hasSuffix:@"\r"] &&
        [scrubbed hasSuffix:@"\n"]) {
        [scrubbed deleteCharactersInRange:NSMakeRange(scrubbed.length - 1, 1)];
    }
    return scrubbed;
}

+ (void)logLevel:(CallWaveLogLevel)level
        category:(NSString *)category
          format:(NSString *)format, ... {
    if (level == CallWaveLogLevelOff || level > CallWaveLog.level) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    // The message is already redacted at the call site, so it is safe to mark
    // public — otherwise every line would read `<private>` in Console.app.
    os_log_with_type(CallWaveOSLog(category), CallWaveOSLogType(level),
                     "%{public}s", message.UTF8String);

    [CallWaveLog.logger callWaveDidLogMessage:message level:level category:category];
}

@end
