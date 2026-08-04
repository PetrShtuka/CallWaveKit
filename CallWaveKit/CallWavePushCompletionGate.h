#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a PushKit completion handler at most once, even when CallKit's reply
/// races the hard deadline. Kept separate so the race can be unit-tested.
@interface CallWavePushCompletionGate : NSObject

@property (nonatomic, assign, readonly, getter=isFinished) BOOL finished;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCompletion:(nullable void (^)(void))completion
    NS_DESIGNATED_INITIALIZER;
/// Returns YES only for the caller that actually ran the completion.
- (BOOL)finish;

@end

NS_ASSUME_NONNULL_END
