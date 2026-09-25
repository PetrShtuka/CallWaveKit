#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Monotonic nanoseconds, including time the device spent asleep, for the
/// answer-latency measurements. Never 0, which the timeline uses as "not yet".
FOUNDATION_EXPORT uint64_t CallWaveMonotonicNanoseconds(void);

/// Milliseconds from `from` to `to`, both from `CallWaveMonotonicNanoseconds`;
/// negative when `to` came first.
FOUNDATION_EXPORT double CallWaveMillisecondsBetween(uint64_t from, uint64_t to);

/// The steps between the host answering a call and two-way audio, in the
/// order they normally happen once the INVITE is already there.
typedef NS_ENUM(NSUInteger, CallWaveAnswerMilestone) {
    /// `on_incoming_call` ran on PJSIP's thread.
    CallWaveAnswerMilestoneInviteReceived = 0,
    /// The INVITE was bound to the call's UUID.
    CallWaveAnswerMilestoneInviteBound,
    /// `-acceptCallWithUUID:…` was called.
    CallWaveAnswerMilestoneAnswerRequested,
    /// `200 OK` was handed to the transport.
    CallWaveAnswerMilestoneAnswerSent,
    /// The audio session became active: CallKit's `didActivate`, the fallback,
    /// or a manual activation.
    CallWaveAnswerMilestoneSessionActivated,
    /// PJSUA reported the call's audio stream active.
    CallWaveAnswerMilestoneMediaActive,
    /// The call's stream was linked to the sound device on the conference
    /// bridge — the moment both directions can carry audio.
    CallWaveAnswerMilestoneAudioConnected,
};

/// When each step of answering one call happened.
///
/// Every milestone is recorded once, the first time it happens, from whatever
/// thread observes it — PJSIP's thread, the SIP queue, the audio session's
/// thread or the host's. The storage is atomic, so no lock is involved.
@interface CallWaveAnswerTimeline : NSObject

/// Records `milestone` at `nanoseconds` unless it is already recorded. YES
/// when this call is the one that recorded it, so its caller logs it once.
- (BOOL)recordMilestone:(CallWaveAnswerMilestone)milestone at:(uint64_t)nanoseconds;

/// When `milestone` happened, or 0 when it has not.
- (uint64_t)timeOfMilestone:(CallWaveAnswerMilestone)milestone;

/// `milestone` relative to `-acceptCall`, for a log line: `+12 ms`,
/// `-1840 ms`, or `before acceptCall` while the host has not answered yet.
- (NSString *)offsetOfMilestone:(CallWaveAnswerMilestone)milestone;

/// Every milestone with its offset from `-acceptCall`, in one line.
- (NSString *)summary;

+ (NSString *)nameOfMilestone:(CallWaveAnswerMilestone)milestone;

@end

NS_ASSUME_NONNULL_END
