#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

@class CallWaveCall;
@class CallWaveCallRegistry;
@class CallWaveCallStateMachine;

/// The machine owns the transition; the delegate owns the side effects that
/// follow it — the client delegate callback, the public event and statistics
/// sampling.
@protocol CallWaveCallStateMachineDelegate <NSObject>

- (void)callStateMachine:(CallWaveCallStateMachine *)machine
        didPublishState:(CallWaveCallState)state
                forUUID:(NSUUID *)uuid;

@end

/// Call-state ownership that used to live inline in `CallWaveClient`:
///
/// - the per-call `state` written into the registry;
/// - the aggregate `state` the client reports;
/// - the "current call" projection (`currentCallUUID`, `currentCaller`,
///   `microphoneMuted`) and the rules for adopting, re-pointing and resetting
///   it — including the cancellation-window case where the record outlives the
///   user's decision;
/// - the resolution policy for argument-less call actions.
///
/// Every method must run on the main queue, exactly like the code it replaces.
/// The machine emits no events and touches no PJSIP: both stay with the
/// delegate, which is what makes every race here unit-testable.
@interface CallWaveCallStateMachine : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithRegistry:(CallWaveCallRegistry *)registry NS_DESIGNATED_INITIALIZER;

@property (nonatomic, weak, nullable) id<CallWaveCallStateMachineDelegate> delegate;

/// The last published state, matching the historical aggregate `callState`.
@property (nonatomic, assign, readonly) CallWaveCallState state;
@property (nonatomic, strong, nullable, readonly) NSUUID *currentCallUUID;
@property (nonatomic, copy, nullable, readonly) NSString *currentCaller;
@property (nonatomic, assign, readonly, getter=isMicrophoneMuted) BOOL microphoneMuted;

/// Applies `state` to the call, adopts it as current when it is the current
/// call or none is, updates the aggregate and notifies the delegate.
- (void)publishState:(CallWaveCallState)state forUUID:(NSUUID *)uuid;

/// Points the projection at `call` without touching its state — the incoming
/// flows do this the moment a call is registered.
- (void)adoptCurrentCall:(CallWaveCall *)call;

/// Moves the projection off `uuid` to the most recent remaining call, without
/// touching the registry — for a call whose record has to outlive the user's
/// decision (a cancellation waiting for its late INVITE).
- (void)detachIfCurrentUUID:(nullable NSUUID *)uuid;

/// Removes the call from the registry and detaches it if it was current.
- (void)clearCallWithUUID:(nullable NSUUID *)uuid;

/// Engine stop and CallKit provider reset: every call is gone.
- (void)resetToIdle;

/// Mirrors a per-call mute into the projection when the call is current.
- (void)setMicrophoneMuted:(BOOL)muted forCall:(CallWaveCall *)call;

/// Resolves the call an argument-less action should act on: the explicit UUID,
/// otherwise the current call, otherwise the most recent one.
- (nullable CallWaveCall *)resolveCallForUUID:(nullable NSUUID *)uuid;

@end

NS_ASSUME_NONNULL_END
