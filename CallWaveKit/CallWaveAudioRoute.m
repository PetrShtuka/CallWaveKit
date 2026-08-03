#import "CallWaveAudioRouteInternal.h"

#import <AVFoundation/AVFoundation.h>

@implementation CallWaveAudioRoute

- (instancetype)initWithInputPortTypes:(NSArray<NSString *> *)inputPortTypes
                       outputPortTypes:(NSArray<NSString *> *)outputPortTypes {
    self = [super init];
    if (self) {
        _inputPortTypes = [inputPortTypes copy] ?: @[];
        _outputPortTypes = [outputPortTypes copy] ?: @[];
        _speakerActive = [_outputPortTypes containsObject:AVAudioSessionPortBuiltInSpeaker];
        NSSet<NSString *> *bluetooth = [NSSet setWithObjects:
                                        AVAudioSessionPortBluetoothHFP,
                                        AVAudioSessionPortBluetoothA2DP,
                                        AVAudioSessionPortBluetoothLE, nil];
        _bluetoothActive = NO;
        for (NSString *type in [_inputPortTypes arrayByAddingObjectsFromArray:_outputPortTypes]) {
            if ([bluetooth containsObject:type]) {
                _bluetoothActive = YES;
                break;
            }
        }
    }
    return self;
}

+ (instancetype)routeForAudioSession:(AVAudioSession *)session {
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    NSMutableArray<NSString *> *outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in session.currentRoute.inputs) {
        [inputs addObject:port.portType];
    }
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs) {
        [outputs addObject:port.portType];
    }
    return [[self alloc] initWithInputPortTypes:inputs outputPortTypes:outputs];
}

- (id)copyWithZone:(NSZone *)zone {
    return [[CallWaveAudioRoute allocWithZone:zone]
            initWithInputPortTypes:self.inputPortTypes
            outputPortTypes:self.outputPortTypes];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: input=%@ output=%@>",
            NSStringFromClass(self.class), self.inputPortTypes, self.outputPortTypes];
}

@end
