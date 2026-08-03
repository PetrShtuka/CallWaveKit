#import "CallWaveDiagnosticsSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

@interface CallWaveDiagnosticsSnapshot ()

- (instancetype)initWithRunning:(BOOL)running
              registrationState:(CallWaveRegistrationState)registrationState
       registrationSIPStatusCode:(NSInteger)registrationSIPStatusCode
                     networkPath:(NSString *)networkPath
                      audioRoute:(CallWaveAudioRoute *)audioRoute
                 activeCallUUIDs:(NSArray<NSUUID *> *)activeCallUUIDs
                  callStatistics:(NSDictionary<NSUUID *, CallWaveCallStatistics *> *)callStatistics;

@end

NS_ASSUME_NONNULL_END
