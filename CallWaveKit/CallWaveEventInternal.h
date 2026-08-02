#import "CallWaveEvent.h"

NS_ASSUME_NONNULL_BEGIN

@interface CallWaveEvent ()

@property (nonatomic, assign, readwrite) CallWaveEventType type;
@property (nonatomic, strong, readwrite, nullable) NSUUID *callUUID;
@property (nonatomic, assign, readwrite) CallWaveCallState callState;
@property (nonatomic, assign, readwrite) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readwrite) NSInteger statusCode;
@property (nonatomic, copy, readwrite, nullable) NSString *caller;
@property (nonatomic, copy, readwrite, nullable) NSString *pushToken;
@property (nonatomic, assign, readwrite) CXCallEndedReason endedReason;
@property (nonatomic, strong, readwrite, nullable) NSError *error;

- (instancetype)initInternal;
+ (instancetype)eventWithType:(CallWaveEventType)type;

@end

NS_ASSUME_NONNULL_END
