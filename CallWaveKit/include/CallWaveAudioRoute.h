#import <Foundation/Foundation.h>

#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

/// A sanitized snapshot of the active AVAudioSession route.
NS_SWIFT_SENDABLE
@interface CallWaveAudioRoute : NSObject <NSCopying>

/// AVAudioSession port type strings. They contain no device names or IDs.
@property (nonatomic, copy, readonly) NSArray<NSString *> *inputPortTypes;
@property (nonatomic, copy, readonly) NSArray<NSString *> *outputPortTypes;
@property (nonatomic, assign, readonly, getter=isSpeakerActive) BOOL speakerActive;
@property (nonatomic, assign, readonly, getter=isBluetoothActive) BOOL bluetoothActive;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
