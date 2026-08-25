#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test-facing view of the teardown observer. The observer itself is private to
/// `CallWaveClient.m`; these two answer the questions a test has to ask, and a
/// declined call cannot be verified any other way — PJSUA reports nothing about
/// it once the invite session is gone.

/// Whether the observer is attached to the PJSIP endpoint. `NO` after the
/// engine is stopped, and `NO` if registration failed, in which case a declined
/// call's ACK is neither reported nor waited for.
BOOL CallWaveTeardownObserverIsRegistered(void);

/// Non-2xx final responses to an INVITE that have gone out and not yet been
/// ACKed. This is the drain condition for the decline path;
/// `pjsua_call_get_count()` is blind to it.
unsigned CallWaveTeardownPendingFinalResponses(void);

NS_ASSUME_NONNULL_END
