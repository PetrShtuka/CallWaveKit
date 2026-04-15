#ifndef PJSIPThreadManager_h
#define PJSIPThreadManager_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages PJSIP thread registration for safe cross-thread access.
/// PJSIP requires all threads calling its API to be registered first.
@interface PJSIPThreadManager : NSObject

/// Ensures the current thread is registered with PJSIP.
/// Safe to call multiple times — only registers once per thread.
+ (BOOL)ensureRegistered:(NSString *)name;

/// Cleans up all registered thread descriptors. Call on shutdown.
+ (void)cleanup;

@end

NS_ASSUME_NONNULL_END

#endif /* PJSIPThreadManager_h */
