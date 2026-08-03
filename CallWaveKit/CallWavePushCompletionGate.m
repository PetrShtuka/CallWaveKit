#import "CallWavePushCompletionGate.h"

#import <os/lock.h>

@implementation CallWavePushCompletionGate {
    os_unfair_lock _lock;
    void (^_completion)(void);
    BOOL _finished;
}

- (instancetype)initWithCompletion:(void (^)(void))completion {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _completion = [completion copy];
    }
    return self;
}

- (BOOL)isFinished {
    os_unfair_lock_lock(&_lock);
    BOOL finished = _finished;
    os_unfair_lock_unlock(&_lock);
    return finished;
}

- (BOOL)finish {
    os_unfair_lock_lock(&_lock);
    if (_finished) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    _finished = YES;
    void (^completion)(void) = _completion;
    _completion = nil;
    os_unfair_lock_unlock(&_lock);
    if (completion != nil) {
        completion();
    }
    return YES;
}

@end
