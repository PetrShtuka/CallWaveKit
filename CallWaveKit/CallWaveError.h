#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// A local failure with no network status behind it.
FOUNDATION_EXPORT NSError *CallWaveMakeError(CallWaveErrorCode code, NSString *description);

/// A failure PJSIP reported, carrying the raw `pj_status_t` in
/// `CallWaveErrorPJStatusKey` and the operation name in
/// `CallWaveErrorOperationKey`. `status` is a `pj_status_t`.
FOUNDATION_EXPORT NSError *CallWaveMakeSIPError(int status, NSString *operation);

/// A failure the registrar or the peer reported, carrying the SIP status code
/// in `CallWaveErrorSIPStatusCodeKey`.
FOUNDATION_EXPORT NSError *CallWaveMakeSIPStatusError(NSInteger statusCode,
                                                      NSString *_Nullable reason,
                                                      NSString *operation);

NS_ASSUME_NONNULL_END
