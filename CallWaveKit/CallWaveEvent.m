#import "CallWaveEventInternal.h"

@implementation CallWaveEvent

+ (instancetype)eventWithType:(CallWaveEventType)type {
    CallWaveEvent *event = [[CallWaveEvent alloc] initInternal];
    event.type = type;
    return event;
}

- (instancetype)initInternal {
    self = [super init];
    if (self) {
        _callState = CallWaveCallStateIdle;
        _registrationState = CallWaveRegistrationStateStopped;
        _endedReason = CXCallEndedReasonFailed;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: type %ld, call %@>",
            NSStringFromClass(self.class), (long)self.type, self.callUUID.UUIDString ?: @"-"];
}

@end
