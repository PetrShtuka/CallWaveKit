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
@property (nonatomic, strong, readwrite, nullable) CallWaveAudioRoute *audioRoute;
@property (nonatomic, assign, readwrite, getter=isAudioSessionInterrupted) BOOL audioSessionInterrupted;
@property (nonatomic, strong, readwrite, nullable) CallWaveCallStatistics *callStatistics;
@property (nonatomic, assign, readwrite) CallWaveCallQualityWarning qualityWarning;
@property (nonatomic, assign, readwrite) CXCallEndedReason endedReason;
@property (nonatomic, strong, readwrite, nullable) NSError *error;

- (instancetype)initInternal;
+ (instancetype)eventWithType:(CallWaveEventType)type;

@end

NS_ASSUME_NONNULL_END
