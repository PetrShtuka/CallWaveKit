#import <Foundation/Foundation.h>

#import "CallWaveTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Mirrors `pjsua_call_id` without dragging the PJSIP headers into this file,
/// so the registry stays usable from code that must not see the C stack.
typedef int CallWaveSIPCallId;
FOUNDATION_EXPORT const CallWaveSIPCallId CallWaveSIPCallIdInvalid;

/// One call, from the moment either the VoIP push or the INVITE announces it
/// until it is cleared.
///
/// A call object is only mutated while the registry lock is held; read its
/// properties through the registry's accessors rather than caching it.
@interface CallWaveCall : NSObject

@property (nonatomic, strong, readonly) NSUUID *uuid;
/// `CallWaveSIPCallIdInvalid` until the INVITE for this UUID is matched.
@property (nonatomic, assign) CallWaveSIPCallId callId;
/// Raw `remote_info` or push payload value.
@property (nonatomic, copy) NSString *caller;
/// `caller` reduced to something worth showing on the lock screen.
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) CallWaveCallState state;
@property (nonatomic, assign) BOOL reportedToCallKit;
@property (nonatomic, assign) BOOL onHold;
@property (nonatomic, assign) BOOL microphoneMuted;
@property (nonatomic, strong, readonly) NSDate *createdAt;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithUUID:(NSUUID *)uuid NS_DESIGNATED_INITIALIZER;

@end

/// Thread-safe two-way index of the calls the client knows about.
///
/// PJSIP delivers `on_call_state` and `on_incoming_call` on its own worker
/// threads while the main queue is reporting to CallKit, so both directions of
/// the mapping have to be readable without hopping queues.
@interface CallWaveCallRegistry : NSObject

@property (nonatomic, assign, readonly) NSUInteger count;

- (nullable CallWaveCall *)callForUUID:(nullable NSUUID *)uuid;
- (nullable CallWaveCall *)callForCallId:(CallWaveSIPCallId)callId;
/// The oldest call that was announced by a push but whose INVITE has not
/// arrived yet, so a fresh INVITE can be matched to it.
- (nullable CallWaveCall *)callAwaitingInvite;
/// The call `currentCallUUID` should point at: the most recently created call
/// that has not ended.
- (nullable CallWaveCall *)mostRecentCall;
- (NSArray<CallWaveCall *> *)allCalls;

/// Adds `uuid` if it is unknown and returns the call either way.
- (CallWaveCall *)registerCallWithUUID:(NSUUID *)uuid;
/// Binds `callId` to `uuid`, replacing any previous binding for either side.
- (void)bindCallId:(CallWaveSIPCallId)callId toUUID:(NSUUID *)uuid;
- (void)removeCallWithUUID:(nullable NSUUID *)uuid;
- (void)removeCallWithCallId:(CallWaveSIPCallId)callId;
- (NSArray<CallWaveCall *> *)removeAllCalls;

/// Runs `block` with the lock held, for a read-modify-write that has to be
/// atomic. Do not call back into the registry from inside it.
- (void)performLocked:(NS_NOESCAPE dispatch_block_t)block;
/// Lock-free variants for use inside `-performLocked:`.
- (nullable CallWaveCall *)lockedCallForUUID:(nullable NSUUID *)uuid;
- (nullable CallWaveCall *)lockedCallForCallId:(CallWaveSIPCallId)callId;

@end

NS_ASSUME_NONNULL_END
