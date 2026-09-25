#import "CallWaveAnswerTimeline.h"

#import <stdatomic.h>
#import <time.h>

#define CallWaveAnswerMilestoneCount (CallWaveAnswerMilestoneAudioConnected + 1)

uint64_t CallWaveMonotonicNanoseconds(void) {
    // CLOCK_MONOTONIC_RAW keeps counting while the device sleeps, so a push
    // that woke a locked phone is not measured as faster than it was.
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    return now != 0 ? now : 1;
}

double CallWaveMillisecondsBetween(uint64_t from, uint64_t to) {
    return ((double)to - (double)from) / 1e6;
}

@implementation CallWaveAnswerTimeline {
    _Atomic uint64_t _times[CallWaveAnswerMilestoneCount];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        for (NSUInteger index = 0; index < CallWaveAnswerMilestoneCount; index++) {
            atomic_init(&_times[index], 0);
        }
    }
    return self;
}

- (BOOL)recordMilestone:(CallWaveAnswerMilestone)milestone at:(uint64_t)nanoseconds {
    if (milestone >= CallWaveAnswerMilestoneCount || nanoseconds == 0) {
        return NO;
    }
    uint64_t expected = 0;
    return atomic_compare_exchange_strong(&_times[milestone], &expected, nanoseconds);
}

- (uint64_t)timeOfMilestone:(CallWaveAnswerMilestone)milestone {
    if (milestone >= CallWaveAnswerMilestoneCount) {
        return 0;
    }
    return atomic_load(&_times[milestone]);
}

- (NSString *)offsetOfMilestone:(CallWaveAnswerMilestone)milestone {
    uint64_t at = [self timeOfMilestone:milestone];
    uint64_t requested = [self timeOfMilestone:CallWaveAnswerMilestoneAnswerRequested];
    if (at == 0) {
        return @"not seen";
    }
    if (requested == 0) {
        return @"before acceptCall";
    }
    return [NSString stringWithFormat:@"%+.0f ms", CallWaveMillisecondsBetween(requested, at)];
}

- (NSString *)summary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger index = 0; index < CallWaveAnswerMilestoneCount; index++) {
        CallWaveAnswerMilestone milestone = (CallWaveAnswerMilestone)index;
        if (milestone == CallWaveAnswerMilestoneAnswerRequested) {
            continue;
        }
        [parts addObject:[NSString stringWithFormat:@"%@ %@",
                          [CallWaveAnswerTimeline nameOfMilestone:milestone],
                          [self offsetOfMilestone:milestone]]];
    }
    return [parts componentsJoinedByString:@", "];
}

+ (NSString *)nameOfMilestone:(CallWaveAnswerMilestone)milestone {
    switch (milestone) {
        case CallWaveAnswerMilestoneInviteReceived:   return @"INVITE received";
        case CallWaveAnswerMilestoneInviteBound:      return @"INVITE bound";
        case CallWaveAnswerMilestoneAnswerRequested:  return @"acceptCall";
        case CallWaveAnswerMilestoneAnswerSent:       return @"200 OK sent";
        case CallWaveAnswerMilestoneSessionActivated: return @"audio session active";
        case CallWaveAnswerMilestoneMediaActive:      return @"media active";
        case CallWaveAnswerMilestoneAudioConnected:   return @"audio connected";
    }
    return @"unknown";
}

@end
