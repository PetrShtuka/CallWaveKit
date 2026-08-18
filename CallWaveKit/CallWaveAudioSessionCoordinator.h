#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AVAudioSession;
@class CallWaveAudioRoute;
@class CallWaveAudioSessionCoordinator;

/// Everything the coordinator needs from its owner that is not AVAudioSession:
/// the call registry headcount, the PJSIP sound device (which must be driven
/// from the client's SIP queue) and the public event stream.
@protocol CallWaveAudioSessionCoordinatorDelegate <NSObject>

/// Whether any call is tracked, live or still waiting for its INVITE. Gates
/// session reactivation after an interruption and the CallKit fallback timer.
- (BOOL)audioCoordinatorHasTrackedCalls:(CallWaveAudioSessionCoordinator *)coordinator;

/// Open the PJSIP sound device and re-link the conference bridge. The
/// coordinator has already marked the session active; the delegate performs
/// the pjsua work on the SIP queue.
- (void)audioCoordinatorRequestsSoundDeviceStart:(CallWaveAudioSessionCoordinator *)coordinator;

/// Drop the PJSIP sound device after an interruption began or CallKit
/// deactivated the session.
- (void)audioCoordinatorRequestsSoundDeviceStop:(CallWaveAudioSessionCoordinator *)coordinator;

/// The published route changed; already called on the main queue. The
/// delegate turns it into a `CallWaveEventTypeAudioRouteChanged` event.
- (void)audioCoordinator:(CallWaveAudioSessionCoordinator *)coordinator
     didUpdateAudioRoute:(CallWaveAudioRoute *)route;

/// An interruption began or ended; already called on the main queue. The
/// delegate turns it into a `CallWaveEventTypeAudioSessionInterrupted` event.
- (void)audioCoordinator:(CallWaveAudioSessionCoordinator *)coordinator
       interruptionBegan:(BOOL)began;

@end

/// Owns the AVAudioSession of the call: category, activation, the speaker
/// override and its restoration across route changes, interruption and
/// media-services-reset handling, and the published `currentAudioRoute`.
/// PJSIP never appears here — the sound device is the delegate's job, which
/// is what keeps every race in this class testable without a SIP stack.
@interface CallWaveAudioSessionCoordinator : NSObject

@property (nonatomic, weak, nullable) id<CallWaveAudioSessionCoordinatorDelegate> delegate;

/// Written by CallKit activation/deactivation, interruption handling and the
/// fallback timer. Read by the client when linking conference media.
@property (nonatomic, assign) BOOL audioSessionActive;

/// The user's speaker choice. Survives route losses and session reactivation;
/// only `-setSpeakerEnabled:error:` changes it.
@property (nonatomic, assign) BOOL desiredSpeakerEnabled;

@property (nonatomic, strong, readonly) CallWaveAudioRoute *currentAudioRoute;

- (BOOL)configureAudioSessionWithError:(NSError **_Nullable)error;
- (BOOL)activateAudioSessionWithError:(NSError **_Nullable)error;
- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError **_Nullable)error;

/// CallKit does not always deliver `didActivateAudioSession` — most often on
/// a cold start answered from the lock screen. The client schedules this after
/// accepting a call; it activates the session manually when CallKit did not.
- (void)scheduleAudioSessionFallback;

/// Entry points for the CallKit provider delegate.
- (void)audioSessionDidActivate:(AVAudioSession *)audioSession;
- (void)audioSessionDidDeactivate:(AVAudioSession *)audioSession;

/// Entry points for the AVAudioSession notifications the coordinator observes.
/// Exposed so the owner (and tests) can drive them directly.
- (void)handleRouteChangeNotification:(NSNotification *)notification;
- (void)handleInterruptionNotification:(NSNotification *)notification;
- (void)handleMediaServicesResetNotification:(NSNotification *)notification;

@end

NS_ASSUME_NONNULL_END
