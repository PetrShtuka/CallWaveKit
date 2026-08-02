#import "CallWaveCallRegistry.h"

#import <os/lock.h>

const CallWaveSIPCallId CallWaveSIPCallIdInvalid = -1;

@implementation CallWaveCall

- (instancetype)initWithUUID:(NSUUID *)uuid {
    self = [super init];
    if (self) {
        _uuid = uuid;
        _callId = CallWaveSIPCallIdInvalid;
        _caller = @"";
        _displayName = @"";
        _state = CallWaveCallStateIncoming;
        _createdAt = [NSDate date];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@ sip:%d state:%ld>",
            NSStringFromClass(self.class), self.uuid.UUIDString,
            self.callId, (long)self.state];
}

@end

@implementation CallWaveCallRegistry {
    os_unfair_lock _lock;
    NSMutableDictionary<NSUUID *, CallWaveCall *> *_callsByUUID;
    NSMutableDictionary<NSNumber *, CallWaveCall *> *_callsByCallId;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _callsByUUID = [NSMutableDictionary dictionary];
        _callsByCallId = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _callsByUUID.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (CallWaveCall *)lockedCallForUUID:(NSUUID *)uuid {
    return uuid != nil ? _callsByUUID[uuid] : nil;
}

- (CallWaveCall *)lockedCallForCallId:(CallWaveSIPCallId)callId {
    return callId != CallWaveSIPCallIdInvalid ? _callsByCallId[@(callId)] : nil;
}

- (CallWaveCall *)callForUUID:(NSUUID *)uuid {
    os_unfair_lock_lock(&_lock);
    CallWaveCall *call = [self lockedCallForUUID:uuid];
    os_unfair_lock_unlock(&_lock);
    return call;
}

- (CallWaveCall *)callForCallId:(CallWaveSIPCallId)callId {
    os_unfair_lock_lock(&_lock);
    CallWaveCall *call = [self lockedCallForCallId:callId];
    os_unfair_lock_unlock(&_lock);
    return call;
}

- (CallWaveCall *)callAwaitingInvite {
    os_unfair_lock_lock(&_lock);
    CallWaveCall *oldest = nil;
    for (CallWaveCall *call in _callsByUUID.objectEnumerator) {
        if (call.callId != CallWaveSIPCallIdInvalid || call.state == CallWaveCallStateEnded) {
            continue;
        }
        if (oldest == nil || [call.createdAt compare:oldest.createdAt] == NSOrderedAscending) {
            oldest = call;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return oldest;
}

- (CallWaveCall *)mostRecentCall {
    os_unfair_lock_lock(&_lock);
    CallWaveCall *newest = nil;
    for (CallWaveCall *call in _callsByUUID.objectEnumerator) {
        if (call.state == CallWaveCallStateEnded) {
            continue;
        }
        if (newest == nil || [call.createdAt compare:newest.createdAt] == NSOrderedDescending) {
            newest = call;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return newest;
}

- (NSArray<CallWaveCall *> *)allCalls {
    os_unfair_lock_lock(&_lock);
    NSArray<CallWaveCall *> *calls = _callsByUUID.allValues;
    os_unfair_lock_unlock(&_lock);
    return calls;
}

- (CallWaveCall *)registerCallWithUUID:(NSUUID *)uuid {
    os_unfair_lock_lock(&_lock);
    CallWaveCall *call = _callsByUUID[uuid];
    if (call == nil) {
        call = [[CallWaveCall alloc] initWithUUID:uuid];
        _callsByUUID[uuid] = call;
    }
    os_unfair_lock_unlock(&_lock);
    return call;
}

- (void)bindCallId:(CallWaveSIPCallId)callId toUUID:(NSUUID *)uuid {
    if (callId == CallWaveSIPCallIdInvalid || uuid == nil) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    // A call id is recycled by PJSUA as soon as the previous call is gone, so
    // an old binding for the same id must not survive.
    CallWaveCall *previous = _callsByCallId[@(callId)];
    if (previous != nil && ![previous.uuid isEqual:uuid]) {
        previous.callId = CallWaveSIPCallIdInvalid;
    }
    CallWaveCall *call = _callsByUUID[uuid];
    if (call == nil) {
        call = [[CallWaveCall alloc] initWithUUID:uuid];
        _callsByUUID[uuid] = call;
    }
    if (call.callId != CallWaveSIPCallIdInvalid && call.callId != callId) {
        [_callsByCallId removeObjectForKey:@(call.callId)];
    }
    call.callId = callId;
    _callsByCallId[@(callId)] = call;
    os_unfair_lock_unlock(&_lock);
}

- (void)removeCallWithUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    CallWaveCall *call = _callsByUUID[uuid];
    if (call != nil) {
        if (call.callId != CallWaveSIPCallIdInvalid) {
            [_callsByCallId removeObjectForKey:@(call.callId)];
        }
        [_callsByUUID removeObjectForKey:uuid];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)removeCallWithCallId:(CallWaveSIPCallId)callId {
    if (callId == CallWaveSIPCallIdInvalid) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    CallWaveCall *call = _callsByCallId[@(callId)];
    if (call != nil) {
        [_callsByCallId removeObjectForKey:@(callId)];
        [_callsByUUID removeObjectForKey:call.uuid];
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSArray<CallWaveCall *> *)removeAllCalls {
    os_unfair_lock_lock(&_lock);
    NSArray<CallWaveCall *> *calls = _callsByUUID.allValues;
    [_callsByUUID removeAllObjects];
    [_callsByCallId removeAllObjects];
    os_unfair_lock_unlock(&_lock);
    return calls;
}

- (void)performLocked:(NS_NOESCAPE dispatch_block_t)block {
    os_unfair_lock_lock(&_lock);
    block();
    os_unfair_lock_unlock(&_lock);
}

@end
