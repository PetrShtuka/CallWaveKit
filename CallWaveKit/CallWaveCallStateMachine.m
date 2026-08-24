#import "CallWaveCallStateMachine.h"

#import "CallWaveCallRegistry.h"

#import <os/lock.h>

@implementation CallWaveCallStateMachine {
    CallWaveCallRegistry *_registry;

    /// Every mutator here runs on the main queue, but the four published values
    /// are read from wherever the host calls a public method: -resolveCallForUUID:
    /// backs the argument-less call actions, and the client's `callState` /
    /// `currentCallUUID` / `currentCaller` / `microphoneMuted` are pass-throughs
    /// to the ivars below. Unsynchronized, `_currentCallUUID` and
    /// `_currentCaller` over-release under that read rather than merely going
    /// stale. The declared properties stay `nonatomic`; the lock lives in the
    /// accessors, matching CallWaveClient and CallWaveAudioSessionCoordinator.
    os_unfair_lock _stateLock;
    CallWaveCallState _state;
    NSUUID *_currentCallUUID;
    NSString *_currentCaller;
    BOOL _microphoneMuted;
}

- (instancetype)initWithRegistry:(CallWaveCallRegistry *)registry {
    self = [super init];
    if (self) {
        _registry = registry;
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = CallWaveCallStateIdle;
    }
    return self;
}

- (CallWaveCallState)state {
    os_unfair_lock_lock(&_stateLock);
    CallWaveCallState value = _state;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (NSUUID *)currentCallUUID {
    os_unfair_lock_lock(&_stateLock);
    NSUUID *value = _currentCallUUID;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (NSString *)currentCaller {
    os_unfair_lock_lock(&_stateLock);
    NSString *value = _currentCaller;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

// Named for the declared `getter=isMicrophoneMuted`, not for the property: a
// -microphoneMuted here leaves the real getter auto-synthesized and unlocked,
// which is a race the tests catch but a reader would not.
- (BOOL)isMicrophoneMuted {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _microphoneMuted;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

/// The projection moves as one step, so a reader never catches half of it.
/// Must run on the main queue, like every mutator here.
- (void)setProjectionUUID:(nullable NSUUID *)uuid
                   caller:(nullable NSString *)caller
                    muted:(BOOL)muted {
    NSString *copied = [caller copy];
    os_unfair_lock_lock(&_stateLock);
    _currentCallUUID = uuid;
    _currentCaller = copied;
    _microphoneMuted = muted;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)publishState:(CallWaveCallState)state forUUID:(NSUUID *)uuid {
    CallWaveCall *call = [_registry callForUUID:uuid];
    if (call != nil) {
        call.state = state;
        NSUUID *current = self.currentCallUUID;
        if ([uuid isEqual:current] || current == nil) {
            [self setProjectionUUID:uuid
                             caller:call.displayName
                              muted:call.microphoneMuted];
        }
    }
    os_unfair_lock_lock(&_stateLock);
    _state = state;
    os_unfair_lock_unlock(&_stateLock);
    [self.delegate callStateMachine:self didPublishState:state forUUID:uuid];
}

- (void)adoptCurrentCall:(CallWaveCall *)call {
    [self setProjectionUUID:call.uuid caller:call.displayName muted:self.isMicrophoneMuted];
}

- (void)detachIfCurrentUUID:(NSUUID *)uuid {
    if (uuid == nil || ![uuid isEqual:self.currentCallUUID]) {
        return;
    }
    CallWaveCall *next = [_registry mostRecentCall];
    [self setProjectionUUID:next.uuid
                     caller:next.displayName
                      muted:next != nil ? next.microphoneMuted : NO];
}

- (void)clearCallWithUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }
    [_registry removeCallWithUUID:uuid];
    [self detachIfCurrentUUID:uuid];
}

- (void)resetToIdle {
    [self setProjectionUUID:nil caller:nil muted:NO];
    os_unfair_lock_lock(&_stateLock);
    _state = CallWaveCallStateIdle;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)setMicrophoneMuted:(BOOL)muted forCall:(CallWaveCall *)call {
    os_unfair_lock_lock(&_stateLock);
    if ([call.uuid isEqual:_currentCallUUID]) {
        _microphoneMuted = muted;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (nullable CallWaveCall *)resolveCallForUUID:(NSUUID *)uuid {
    if (uuid != nil) {
        return [_registry callForUUID:uuid];
    }
    NSUUID *current = self.currentCallUUID;
    CallWaveCall *call = current != nil ? [_registry callForUUID:current] : nil;
    return call ?: [_registry mostRecentCall];
}

@end
