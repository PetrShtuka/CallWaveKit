#import "CallWaveError.h"

#if __has_include(<PJSIP/pjlib.h>)
#import <PJSIP/pjlib.h>
#else
#import <pjlib.h>
#endif

NSError *CallWaveMakeError(CallWaveErrorCode code, NSString *description) {
    return [NSError errorWithDomain:CallWaveErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

NSError *CallWaveMakeSIPError(int status, NSString *operation) {
    char reason[PJ_ERR_MSG_SIZE] = {0};
    pj_strerror((pj_status_t)status, reason, sizeof(reason));
    NSString *text = [NSString stringWithFormat:@"%@ failed: %s (%d).",
                      operation, reason, status];
    return [NSError errorWithDomain:CallWaveErrorDomain
                               code:CallWaveErrorSIPFailure
                           userInfo:@{
        NSLocalizedDescriptionKey: text,
        NSLocalizedFailureReasonErrorKey: @(reason),
        CallWaveErrorPJStatusKey: @(status),
        CallWaveErrorOperationKey: operation,
    }];
}

NSError *CallWaveMakeSIPStatusError(NSInteger statusCode,
                                    NSString *reason,
                                    NSString *operation) {
    NSString *text = reason.length > 0
        ? [NSString stringWithFormat:@"%@ failed: %ld %@.", operation, (long)statusCode, reason]
        : [NSString stringWithFormat:@"%@ failed with SIP status %ld.", operation, (long)statusCode];

    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [@{
        NSLocalizedDescriptionKey: text,
        CallWaveErrorSIPStatusCodeKey: @(statusCode),
        CallWaveErrorOperationKey: operation,
    } mutableCopy];
    if (reason.length > 0) {
        userInfo[NSLocalizedFailureReasonErrorKey] = reason;
    }
    return [NSError errorWithDomain:CallWaveErrorDomain
                               code:CallWaveErrorSIPFailure
                           userInfo:userInfo];
}
