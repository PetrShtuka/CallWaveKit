#import "CallWaveCallStateMachine.h"

#import "CallWaveCallRegistry.h"

@implementation CallWaveCallStateMachine {
    CallWaveCallRegistry *_registry;
}

- (instancetype)initWithRegistry:(CallWaveCallRegistry *)registry {
    self = [super init];
    if (self) {
        _registry = registry;
        _state = CallWaveCallStateIdle;
    }
    return self;
}

- (void)publishState:(CallWaveCallState)state forUUID:(NSUUID *)uuid {
    CallWaveCall *call = [_registry callForUUID:uuid];
    if (call != nil) {
        call.state = state;
        if ([uuid isEqual:_currentCallUUID] || _currentCallUUID == nil) {
            _currentCallUUID = uuid;
            _currentCaller = call.displayName;
            _microphoneMuted = call.microphoneMuted;
        }
    }
    _state = state;
    [self.delegate callStateMachine:self didPublishState:state forUUID:uuid];
}

- (void)adoptCurrentCall:(CallWaveCall *)call {
    _currentCallUUID = call.uuid;
    _currentCaller = call.displayName;
}

- (void)detachIfCurrentUUID:(NSUUID *)uuid {
    if (uuid == nil || ![uuid isEqual:_currentCallUUID]) {
        return;
    }
    CallWaveCall *next = [_registry mostRecentCall];
    _currentCallUUID = next.uuid;
    _currentCaller = next.displayName;
    _microphoneMuted = next != nil ? next.microphoneMuted : NO;
}

- (void)clearCallWithUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }
    [_registry removeCallWithUUID:uuid];
    [self detachIfCurrentUUID:uuid];
}

- (void)resetToIdle {
    _currentCallUUID = nil;
    _currentCaller = nil;
    _microphoneMuted = NO;
    _state = CallWaveCallStateIdle;
}

- (void)setMicrophoneMuted:(BOOL)muted forCall:(CallWaveCall *)call {
    if ([call.uuid isEqual:_currentCallUUID]) {
        _microphoneMuted = muted;
    }
}

- (nullable CallWaveCall *)resolveCallForUUID:(NSUUID *)uuid {
    if (uuid != nil) {
        return [_registry callForUUID:uuid];
    }
    NSUUID *current = _currentCallUUID;
    CallWaveCall *call = current != nil ? [_registry callForUUID:current] : nil;
    return call ?: [_registry mostRecentCall];
}

@end
