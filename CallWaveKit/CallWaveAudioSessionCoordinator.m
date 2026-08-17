#import "CallWaveAudioSessionCoordinator.h"

#import "CallWaveAudioRouteInternal.h"
#import "CallWaveError.h"
#import "CallWaveLogInternal.h"

#import <AVFoundation/AVFoundation.h>

/// Delay before the manual session activation that covers CallKit never
/// delivering `didActivateAudioSession` (cold start from the lock screen).
static const NSTimeInterval CallWaveAudioFallbackDelay = 1.5;

static void callWaveAudioDispatchMain(dispatch_block_t block) {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@implementation CallWaveAudioSessionCoordinator

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentAudioRoute = [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(handleRouteChangeNotification:)
                       name:AVAudioSessionRouteChangeNotification object:nil];
        [center addObserver:self selector:@selector(handleInterruptionNotification:)
                       name:AVAudioSessionInterruptionNotification object:nil];
        [center addObserver:self selector:@selector(handleMediaServicesResetNotification:)
                       name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Route publishing

- (void)publishCurrentAudioRoute {
    callWaveAudioDispatchMain(^{
        self->_currentAudioRoute =
            [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance];
        [self.delegate audioCoordinator:self didUpdateAudioRoute:self->_currentAudioRoute];
    });
}

#pragma mark - Session configuration and activation

- (BOOL)configureAudioSessionWithError:(NSError **)error {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *categoryError = nil;
    AVAudioSessionCategoryOptions options =
#if defined(__IPHONE_26_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_26_0
        AVAudioSessionCategoryOptionAllowBluetoothHFP |
#else
        // Renamed to …AllowBluetoothHFP in the iOS 26 SDK; same raw value.
        AVAudioSessionCategoryOptionAllowBluetooth |
#endif
        AVAudioSessionCategoryOptionDefaultToSpeaker;
    if ([session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeVoiceChat
                     options:options
                       error:&categoryError]) {
        return YES;
    }
    CWLogError(CallWaveLogCategoryAudio, @"category configuration failed: %@", categoryError);
    if (error != NULL) {
        *error = categoryError ?: CallWaveMakeError(CallWaveErrorAudioSessionFailure,
                                                    @"The audio category could not be set.");
    }
    return NO;
}

- (BOOL)activateAudioSessionWithError:(NSError **)error {
    [self configureAudioSessionWithError:error];
    NSError *activationError = nil;
    if (![AVAudioSession.sharedInstance setActive:YES
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                            error:&activationError]) {
        CWLogError(CallWaveLogCategoryAudio, @"activation failed: %@", activationError);
        if (error != NULL) {
            *error = activationError ?: CallWaveMakeError(CallWaveErrorAudioSessionFailure,
                                                          @"The audio session could not be activated.");
        }
        return NO;
    }

    [self openSoundDevice];
    if (self.desiredSpeakerEnabled) {
        [AVAudioSession.sharedInstance overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                                         error:NULL];
    }
    [self publishCurrentAudioRoute];
    return YES;
}

/// Marks the session active and asks the delegate to open the PJSIP sound
/// device and re-link the conference bridge. Safe to call more than once.
- (void)openSoundDevice {
    self.audioSessionActive = YES;
    [self.delegate audioCoordinatorRequestsSoundDeviceStart:self];
}

/// CallKit does not always deliver `didActivateAudioSession` — most often on
/// a cold start answered from the lock screen. Activating the session manually
/// a moment later is what keeps two-way audio working.
- (void)scheduleAudioSessionFallback {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(CallWaveAudioFallbackDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.audioSessionActive ||
            ![self.delegate audioCoordinatorHasTrackedCalls:self]) {
            return;
        }
        CWLogWarning(CallWaveLogCategoryAudio,
                     @"CallKit did not activate the session, activating manually");
        [self activateAudioSessionWithError:NULL];
    });
}

- (void)audioSessionDidActivate:(AVAudioSession *)audioSession {
    [self openSoundDevice];
    if (self.desiredSpeakerEnabled) {
        [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:NULL];
    }
    [self publishCurrentAudioRoute];
}

- (void)audioSessionDidDeactivate:(AVAudioSession *)audioSession {
    self.audioSessionActive = NO;
    [self.delegate audioCoordinatorRequestsSoundDeviceStop:self];
    [self publishCurrentAudioRoute];
}

#pragma mark - Speaker

- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError **)error {
    [self configureAudioSessionWithError:NULL];
    NSError *routeError = nil;
    BOOL changed = [AVAudioSession.sharedInstance
        overrideOutputAudioPort:enabled ? AVAudioSessionPortOverrideSpeaker
                                        : AVAudioSessionPortOverrideNone
                          error:&routeError];
    if (!changed) {
        CWLogError(CallWaveLogCategoryAudio, @"route change failed: %@", routeError);
        if (error != NULL) {
            *error = routeError ?: CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                     @"Audio route could not be changed.");
        }
    }
    if (changed) {
        self.desiredSpeakerEnabled = enabled;
        [self publishCurrentAudioRoute];
    }
    return changed;
}

#pragma mark - AVAudioSession notifications

- (void)handleRouteChangeNotification:(NSNotification *)notification {
    CallWaveAudioRoute *route =
        [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance];
    if (self.desiredSpeakerEnabled && !route.isSpeakerActive) {
        NSError *error = nil;
        [AVAudioSession.sharedInstance overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                                         error:&error];
        if (error != nil) {
            CWLogWarning(CallWaveLogCategoryAudio,
                         @"could not restore the speaker after a route change: %@", error);
        }
    }
    [self publishCurrentAudioRoute];
}

- (void)handleInterruptionNotification:(NSNotification *)notification {
    NSNumber *rawType = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)rawType.unsignedIntegerValue;
    BOOL began = type == AVAudioSessionInterruptionTypeBegan;
    if (began) {
        self.audioSessionActive = NO;
        [self.delegate audioCoordinatorRequestsSoundDeviceStop:self];
    } else {
        NSNumber *rawOptions = notification.userInfo[AVAudioSessionInterruptionOptionKey];
        AVAudioSessionInterruptionOptions options = rawOptions.unsignedIntegerValue;
        if ((options & AVAudioSessionInterruptionOptionShouldResume) != 0 &&
            [self.delegate audioCoordinatorHasTrackedCalls:self]) {
            [self activateAudioSessionWithError:NULL];
        }
    }
    callWaveAudioDispatchMain(^{
        [self.delegate audioCoordinator:self interruptionBegan:began];
    });
}

- (void)handleMediaServicesResetNotification:(NSNotification *)notification {
    CWLogWarning(CallWaveLogCategoryAudio, @"audio media services were reset");
    self.audioSessionActive = NO;
    [self configureAudioSessionWithError:NULL];
    if ([self.delegate audioCoordinatorHasTrackedCalls:self]) {
        [self activateAudioSessionWithError:NULL];
    }
    [self publishCurrentAudioRoute];
}

@end
