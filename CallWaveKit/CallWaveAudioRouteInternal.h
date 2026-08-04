#import "CallWaveAudioRoute.h"

@class AVAudioSession;

NS_ASSUME_NONNULL_BEGIN

@interface CallWaveAudioRoute ()

- (instancetype)initWithInputPortTypes:(NSArray<NSString *> *)inputPortTypes
                       outputPortTypes:(NSArray<NSString *> *)outputPortTypes;
+ (instancetype)routeForAudioSession:(AVAudioSession *)session;

@end

NS_ASSUME_NONNULL_END
