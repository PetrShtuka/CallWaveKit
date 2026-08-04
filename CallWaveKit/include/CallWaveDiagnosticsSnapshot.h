#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

#if !defined(NS_SWIFT_SENDABLE)
#define NS_SWIFT_SENDABLE
#endif

NS_ASSUME_NONNULL_BEGIN

@class CallWaveAudioRoute;
@class CallWaveCallStatistics;

/// A credential-free point-in-time view suitable for a support attachment.
NS_SWIFT_SENDABLE
@interface CallWaveDiagnosticsSnapshot : NSObject

@property (nonatomic, strong, readonly) NSDate *timestamp;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign, readonly) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readonly) NSInteger registrationSIPStatusCode;
@property (nonatomic, copy, readonly) NSString *networkPath;
@property (nonatomic, strong, readonly) CallWaveAudioRoute *audioRoute;
@property (nonatomic, copy, readonly) NSArray<NSUUID *> *activeCallUUIDs;
@property (nonatomic, copy, readonly) NSDictionary<NSUUID *, CallWaveCallStatistics *> *callStatistics;

- (instancetype)init NS_UNAVAILABLE;

/// JSON-compatible values only; never includes SIP/TURN credentials or URIs.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

@end

NS_ASSUME_NONNULL_END
