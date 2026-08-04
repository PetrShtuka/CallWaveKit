#import <XCTest/XCTest.h>

#import "CallWavePushCompletionGate.h"

@interface CallWavePushCompletionGateTests : XCTestCase
@end

@implementation CallWavePushCompletionGateTests

- (void)testCompletionRunsOnceAcrossCompetingFinishers {
    __block NSInteger count = 0;
    NSObject *lock = [[NSObject alloc] init];
    CallWavePushCompletionGate *gate =
        [[CallWavePushCompletionGate alloc] initWithCompletion:^{
        @synchronized (lock) { count += 1; }
    }];

    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger index = 0; index < 50; index++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [gate finish];
        });
    }
    XCTAssertEqual(dispatch_group_wait(group,
                                       dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertEqual(count, 1);
    XCTAssertTrue(gate.isFinished);
    XCTAssertFalse([gate finish]);
}

- (void)testNilCompletionStillFinishesOnce {
    CallWavePushCompletionGate *gate =
        [[CallWavePushCompletionGate alloc] initWithCompletion:nil];
    XCTAssertTrue([gate finish]);
    XCTAssertFalse([gate finish]);
}

@end
