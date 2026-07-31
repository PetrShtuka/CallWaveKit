#import "CallWaveClient.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CallKit/CallKit.h>
#import <PushKit/PushKit.h>
#import <UIKit/UIKit.h>
#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif
#import <pthread.h>

NSErrorDomain const CallWaveErrorDomain = @"com.callwave.kit";

static pj_bool_t gPJInitialized = PJ_FALSE;
static pj_bool_t gPJSUACreated = PJ_FALSE;
static pj_bool_t gPJSUAStarted = PJ_FALSE;
static pjsua_acc_id gAccountId = PJSUA_INVALID_ID;
static __weak CallWaveClient *gActiveClient = nil;

static void onIncomingCall(pjsua_acc_id accId, pjsua_call_id callId, pjsip_rx_data *rdata);
static void onCallState(pjsua_call_id callId, pjsip_event *event);
static void onCallMediaState(pjsua_call_id callId);
static void onRegistrationState(pjsua_acc_id accId);

static pthread_key_t gPJThreadKey;
static pthread_once_t gPJThreadKeyOnce = PTHREAD_ONCE_INIT;

static void destroyPJThreadDescriptor(void *value) {
    free(value);
}

static void createPJThreadKey(void) {
    pthread_key_create(&gPJThreadKey, destroyPJThreadDescriptor);
}

/// PJSIP requires foreign GCD/main threads to remain registered for the
/// lifetime of the native thread. A pthread TLS descriptor provides that
/// lifetime and avoids the stack-backed descriptors used previously.
static BOOL ensurePJThreadRegistered(const char *name) {
    if (!gPJInitialized || pj_thread_is_registered()) {
        return YES;
    }

    pthread_once(&gPJThreadKeyOnce, createPJThreadKey);
    pj_thread_desc *descriptor = pthread_getspecific(gPJThreadKey);
    if (descriptor == NULL) {
        descriptor = calloc(1, sizeof(pj_thread_desc));
        if (descriptor == NULL) {
            return NO;
        }
        pthread_setspecific(gPJThreadKey, descriptor);
    }

    pj_thread_t *thread = NULL;
    pj_status_t status = pj_thread_register(name, *descriptor, &thread);
    if (status != PJ_SUCCESS) {
        NSLog(@"SIP: failed to register thread %s (%d)", name, status);
        return NO;
    }
    return YES;
}

static NSString *stringFromPJString(pj_str_t value) {
    if (value.ptr == NULL || value.slen <= 0) {
        return @"";
    }
    return [[NSString alloc] initWithBytes:value.ptr
                                   length:(NSUInteger)value.slen
                                 encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation CallWaveConfiguration

- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents {
    self = [super init];
    if (self) {
        _domain = [domain copy];
        _username = [username copy];
        _password = [password copy];
        _includesCallsInRecents = includesCallsInRecents;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[CallWaveConfiguration allocWithZone:zone]
        initWithDomain:self.domain
              username:self.username
              password:self.password
includesCallsInRecents:self.includesCallsInRecents];
}

@end

@interface CallWaveClient () <CXProviderDelegate, PKPushRegistryDelegate>
@property (nonatomic, strong, readwrite) CallWaveConfiguration *configuration;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign, readwrite) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readwrite) CallWaveCallState callState;
@property (nonatomic, copy, nullable, readwrite) NSString *currentCaller;
@property (nonatomic, strong, readwrite) CXProvider *provider;
@property (nonatomic, strong, readwrite) CXCallController *callController;
@property (nonatomic, strong, readwrite) NSMutableDictionary<NSString *, NSDictionary *> *activeCalls;
@property (nonatomic, strong, readwrite) NSMutableSet<NSString *> *reportedCallUUIDs;
@property (nonatomic, strong, nullable, readwrite) NSUUID *currentCallUUID;
@property (nonatomic, assign, readwrite) pjsua_call_id currentCallIdentifier;
@property (nonatomic, assign, readwrite) pjsua_call_id incoming_call_id;
@property (nonatomic, strong, nullable) CXAnswerCallAction *pendingAnswerAction;
@property (nonatomic, strong, nullable) PKPushRegistry *pushRegistry;
@property (nonatomic, assign) BOOL audioSessionActive;
@property (nonatomic, assign, readwrite) BOOL microphoneMuted;
@property (nonatomic, strong) dispatch_queue_t sipQueue;
@end

@implementation CallWaveClient

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _activeCalls = [NSMutableDictionary dictionary];
        _reportedCallUUIDs = [NSMutableSet set];
        _currentCallIdentifier = PJSUA_INVALID_ID;
        _incoming_call_id = PJSUA_INVALID_ID;
        _registrationState = CallWaveRegistrationStateStopped;
        _callState = CallWaveCallStateIdle;
        _sipQueue = dispatch_queue_create("com.callwave.pjsip", DISPATCH_QUEUE_SERIAL);
        [self setupCallKit];
    }
    return self;
}

- (void)dealloc {
    if (self.isRunning) {
        [self stop];
    }
}

static NSError *CallWaveMakeError(CallWaveErrorCode code, NSString *description) {
    return [NSError errorWithDomain:CallWaveErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (BOOL)validateConfigurationWithError:(NSError **)error {
    if (self.configuration.domain.length > 0 &&
        self.configuration.username.length > 0 &&
        self.configuration.password.length > 0) {
        return YES;
    }
    if (error != NULL) {
        *error = CallWaveMakeError(CallWaveErrorInvalidConfiguration,
                                   @"Domain, username and password are required.");
    }
    return NO;
}

- (BOOL)startWithError:(NSError **)error {
    if (self.isRunning) {
        return YES;
    }
    if (![self validateConfigurationWithError:error]) {
        return NO;
    }

    @synchronized (CallWaveClient.class) {
        if (gActiveClient != nil && gActiveClient != self && gActiveClient.isRunning) {
            if (error != NULL) {
                *error = CallWaveMakeError(CallWaveErrorEngineAlreadyRunning,
                                           @"Another CallWaveClient owns the PJSUA runtime.");
            }
            return NO;
        }
        gActiveClient = self;
    }

    self.registrationState = CallWaveRegistrationStateRegistering;
    pj_status_t status = [self configurePJSIP];
    if (status != PJ_SUCCESS) {
        gActiveClient = nil;
        self.registrationState = CallWaveRegistrationStateFailed;
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorSIPFailure,
                                       [NSString stringWithFormat:@"PJSIP start failed (%d).", status]);
        }
        return NO;
    }
    self.running = YES;
    return YES;
}

- (void)stop {
    if (!self.isRunning && gActiveClient != self) {
        return;
    }

    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveStop");
        if (self.currentCallIdentifier != PJSUA_INVALID_ID &&
            pjsua_call_is_active(self.currentCallIdentifier)) {
            pjsua_call_hangup(self.currentCallIdentifier, 0, NULL, NULL);
        }
        if (gAccountId != PJSUA_INVALID_ID && pjsua_acc_is_valid(gAccountId)) {
            pjsua_acc_set_registration(gAccountId, PJ_FALSE);
            pjsua_acc_del(gAccountId);
        }
        gAccountId = PJSUA_INVALID_ID;
        if (gPJSUACreated) {
            pjsua_destroy();
        }
        gPJSUAStarted = PJ_FALSE;
        gPJSUACreated = PJ_FALSE;
        gPJInitialized = PJ_FALSE;
    });

    self.running = NO;
    self.registrationState = CallWaveRegistrationStateStopped;
    self.callState = CallWaveCallStateIdle;
    self.currentCallUUID = nil;
    self.currentCallIdentifier = PJSUA_INVALID_ID;
    self.incoming_call_id = PJSUA_INVALID_ID;
    self.currentCaller = nil;
    self.microphoneMuted = NO;
    [self.activeCalls removeAllObjects];
    [self.reportedCallUUIDs removeAllObjects];
    if (gActiveClient == self) {
        gActiveClient = nil;
    }
}

#pragma mark - PJSUA lifecycle and registration

- (pj_status_t)configurePJSIP {
    __block pj_status_t result = PJ_SUCCESS;
    dispatch_sync(self.sipQueue, ^{
        if (!gPJSUACreated) {
            result = pjsua_create();
            if (result != PJ_SUCCESS) {
                return;
            }
            gPJSUACreated = PJ_TRUE;
            gPJInitialized = PJ_TRUE;
        }

        if (!ensurePJThreadRegistered("CallWaveConfig")) {
            result = PJ_EUNKNOWN;
            return;
        }

        if (!gPJSUAStarted) {
            pjsua_config config;
            pjsua_logging_config logging;
            pjsua_media_config media;
            pjsua_config_default(&config);
            pjsua_logging_config_default(&logging);
            pjsua_media_config_default(&media);

            config.max_calls = 1;
            config.thread_cnt = 1;
            config.cb.on_incoming_call = &onIncomingCall;
            config.cb.on_call_state = &onCallState;
            config.cb.on_call_media_state = &onCallMediaState;
            config.cb.on_reg_state = &onRegistrationState;

            media.thread_cnt = 1;
            media.has_ioqueue = PJ_TRUE;
            media.no_vad = PJ_TRUE;

            logging.level = 4;
            logging.console_level = 4;
            logging.log_filename = pj_str(NULL);

            result = pjsua_init(&config, &logging, &media);
            if (result != PJ_SUCCESS) {
                return;
            }

            pjsua_transport_config transport;
            pjsua_transport_config_default(&transport);
            transport.port = 0;

            pjsua_transport_id transportId = PJSUA_INVALID_ID;
            result = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transport, &transportId);
            if (result != PJ_SUCCESS) {
                return;
            }

            // TCP is optional. UDP remains the default for existing intercoms.
            pj_status_t tcpStatus = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &transport, NULL);
            if (tcpStatus != PJ_SUCCESS) {
                NSLog(@"SIP: optional TCP transport unavailable (%d)", tcpStatus);
            }

            result = pjsua_start();
            if (result != PJ_SUCCESS) {
                return;
            }
            gPJSUAStarted = PJ_TRUE;
            pjsua_set_no_snd_dev();
        }

        NSString *domain = [self.configuration.domain
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *username = [self.configuration.username
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *password = self.configuration.password;

        if (gAccountId != PJSUA_INVALID_ID && pjsua_acc_is_valid(gAccountId)) {
            result = pjsua_acc_set_registration(gAccountId, PJ_TRUE);
            return;
        }

        NSString *identity = [NSString stringWithFormat:@"sip:%@@%@", username, domain];
        NSString *registrar = [NSString stringWithFormat:@"sip:%@", domain];

        pjsua_acc_config account;
        pjsua_acc_config_default(&account);
        account.id = pj_str((char *)identity.UTF8String);
        account.reg_uri = pj_str((char *)registrar.UTF8String);
        account.cred_count = 1;
        account.cred_info[0].scheme = pj_str("digest");
        account.cred_info[0].realm = pj_str("*");
        account.cred_info[0].username = pj_str((char *)username.UTF8String);
        account.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
        account.cred_info[0].data = pj_str((char *)password.UTF8String);
        account.reg_timeout = 300;
        account.reg_retry_interval = 5;
        account.reg_retry_random_interval = 2;
        account.ka_interval = 15;
        account.allow_contact_rewrite = PJ_TRUE;
        account.contact_use_src_port = PJ_TRUE;

        result = pjsua_acc_add(&account, PJ_TRUE, &gAccountId);
        if (result == PJ_SUCCESS) {
            NSLog(@"SIP: registration started for %@@%@", username, domain);
        }
    });
    return result;
}

- (BOOL)isRegistered {
    if (!gPJSUAStarted || gAccountId == PJSUA_INVALID_ID) {
        return NO;
    }

    __block BOOL registered = NO;
    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveRegistrationCheck");
        if (!pjsua_acc_is_valid(gAccountId)) {
            return;
        }
        pjsua_acc_info info;
        if (pjsua_acc_get_info(gAccountId, &info) == PJ_SUCCESS) {
            registered = info.status == PJSIP_SC_OK && info.expires > 0;
        }
    });
    return registered;
}

- (BOOL)refreshRegistrationWithError:(NSError **)error {
    if (!self.isRunning) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorEngineNotRunning,
                                       @"CallWaveClient must be started first.");
        }
        return NO;
    }
    if (!gPJSUAStarted || gAccountId == PJSUA_INVALID_ID || !pjsua_acc_is_valid(gAccountId)) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorSIPFailure,
                                       @"The SIP account is not available.");
        }
        return NO;
    }

    __block pj_status_t status = PJ_EUNKNOWN;
    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveReRegister");
        status = pjsua_acc_set_registration(gAccountId, PJ_TRUE);
    });
    if (status != PJ_SUCCESS && error != NULL) {
        *error = CallWaveMakeError(CallWaveErrorSIPFailure,
                                   [NSString stringWithFormat:@"Registration refresh failed (%d).", status]);
    }
    return status == PJ_SUCCESS;
}

#pragma mark - Incoming-only calling

- (BOOL)answerSIPCall:(pjsua_call_id)callId {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveAnswer");

    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return NO;
    }
    if (info.state == PJSIP_INV_STATE_CONFIRMED ||
        info.state == PJSIP_INV_STATE_CONNECTING) {
        return YES;
    }
    if (info.state != PJSIP_INV_STATE_INCOMING &&
        info.state != PJSIP_INV_STATE_EARLY) {
        return NO;
    }

    pjsua_call_setting settings;
    pjsua_call_setting_default(&settings);
    settings.aud_cnt = 1;
    settings.vid_cnt = 0;
    return pjsua_call_answer2(callId, &settings, PJSIP_SC_OK, NULL, NULL) == PJ_SUCCESS;
}

- (BOOL)declineCall {
    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveDecline");
    return pjsua_call_answer(callId, PJSIP_SC_DECLINE, NULL, NULL) == PJ_SUCCESS;
}

- (BOOL)stopCall {
    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveHangup");
    return pjsua_call_hangup(callId, 0, NULL, NULL) == PJ_SUCCESS;
}

- (CallWaveCallState)resolvedCallState {
    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return CallWaveCallStateIdle;
    }
    ensurePJThreadRegistered("CallWaveState");
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return CallWaveCallStateIdle;
    }
    if (info.state == PJSIP_INV_STATE_INCOMING ||
        info.state == PJSIP_INV_STATE_EARLY) {
        return CallWaveCallStateIncoming;
    }
    if (info.state == PJSIP_INV_STATE_CONNECTING ||
        info.state == PJSIP_INV_STATE_CONFIRMED ||
        info.state == PJSIP_INV_STATE_CALLING) {
        return info.state == PJSIP_INV_STATE_CONFIRMED
            ? CallWaveCallStateActive
            : CallWaveCallStateConnecting;
    }
    return CallWaveCallStateIdle;
}

- (void)complete:(CallWaveCompletion)completion error:(NSError *)error {
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    }
}

- (void)requestTransactionWithAction:(CXAction *)action
                          completion:(CallWaveCompletion)completion {
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:action];
    [self.callController requestTransaction:transaction completion:^(NSError *error) {
        [self complete:completion error:error];
    }];
}

- (void)answerWithCompletion:(CallWaveCompletion)completion {
    NSUUID *uuid = self.currentCallUUID;
    if (uuid == nil || self.callState != CallWaveCallStateIncoming) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no incoming call to answer.")];
        return;
    }
    [self requestTransactionWithAction:[[CXAnswerCallAction alloc] initWithCallUUID:uuid]
                            completion:completion];
}

- (void)declineWithCompletion:(CallWaveCompletion)completion {
    NSUUID *uuid = self.currentCallUUID;
    if (uuid == nil || self.callState != CallWaveCallStateIncoming) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no incoming call to decline.")];
        return;
    }
    [self requestTransactionWithAction:[[CXEndCallAction alloc] initWithCallUUID:uuid]
                            completion:completion];
}

- (void)hangupWithCompletion:(CallWaveCompletion)completion {
    NSUUID *uuid = self.currentCallUUID;
    if (uuid == nil || self.callState == CallWaveCallStateIdle) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no call to end.")];
        return;
    }
    [self requestTransactionWithAction:[[CXEndCallAction alloc] initWithCallUUID:uuid]
                            completion:completion];
}

- (void)setMuted:(BOOL)muted completion:(CallWaveCompletion)completion {
    NSUUID *uuid = self.currentCallUUID;
    if (uuid == nil || self.callState == CallWaveCallStateIdle) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no call to mute.")];
        return;
    }
    CXSetMutedCallAction *action = [[CXSetMutedCallAction alloc] initWithCallUUID:uuid
                                                                          muted:muted];
    [self requestTransactionWithAction:action completion:completion];
}

#pragma mark - Media

- (void)prepareAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    AVAudioSessionCategoryOptions options =
        AVAudioSessionCategoryOptionAllowBluetoothHFP |
        AVAudioSessionCategoryOptionDefaultToSpeaker;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeVoiceChat
                      options:options
                        error:&error]) {
        NSLog(@"Audio: category configuration failed: %@", error);
    }
}

- (BOOL)activateSoundDevice {
    [self prepareAudioSession];
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance setActive:YES
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                            error:&error]) {
        NSLog(@"Audio: activation failed: %@", error);
        return NO;
    }
    self.audioSessionActive = YES;

    if (gPJSUAStarted) {
        ensurePJThreadRegistered("CallWaveAudio");
        pj_status_t status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                                               PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
        if (status != PJ_SUCCESS) {
            NSLog(@"Audio: PJSIP sound device failed (%d)", status);
            return NO;
        }
        [self connectMediaForCall:self.currentCallIdentifier];
    }
    return YES;
}

- (void)connectMediaForCall:(pjsua_call_id)callId {
    if (!self.audioSessionActive || callId == PJSUA_INVALID_ID) {
        return;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS ||
        info.media_status != PJSUA_CALL_MEDIA_ACTIVE ||
        info.conf_slot == PJSUA_INVALID_ID) {
        return;
    }

    // Remote -> playback is always connected. Capture -> remote is omitted
    // while muted, which produces a real RTP microphone mute.
    pjsua_conf_connect(info.conf_slot, 0);
    if (self.microphoneMuted) {
        pjsua_conf_disconnect(0, info.conf_slot);
    } else {
        pjsua_conf_connect(0, info.conf_slot);
    }
}

- (BOOL)applyMicrophoneMuted:(BOOL)muted {
    _microphoneMuted = muted;
    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return YES;
    }

    ensurePJThreadRegistered("CallWaveMute");
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS ||
        info.conf_slot == PJSUA_INVALID_ID) {
        return NO;
    }

    pj_status_t status = muted
        ? pjsua_conf_disconnect(0, info.conf_slot)
        : pjsua_conf_connect(0, info.conf_slot);
    return status == PJ_SUCCESS;
}

- (void)changeOutputAudioPort:(AVAudioSessionPortOverride)port {
    [self prepareAudioSession];
    NSError *error = nil;
    if (![AVAudioSession.sharedInstance overrideOutputAudioPort:port error:&error]) {
        NSLog(@"Audio: route change failed: %@", error);
    }
}

- (BOOL)setSpeakerEnabled:(BOOL)enabled error:(NSError **)error {
    [self prepareAudioSession];
    NSError *routeError = nil;
    BOOL changed = [AVAudioSession.sharedInstance
        overrideOutputAudioPort:enabled ? AVAudioSessionPortOverrideSpeaker
                                        : AVAudioSessionPortOverrideNone
                         error:&routeError];
    if (!changed && error != NULL) {
        *error = routeError ?: CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                  @"Audio route could not be changed.");
    }
    return changed;
}

- (void)configureAudioSession {
    [self prepareAudioSession];
}

- (void)configureAudioRouting {
    // VoiceChat mode lets iOS choose wired/Bluetooth HFP inputs. Speaker
    // overrides remain available through changeOutputAudioPort:.
}

#pragma mark - Caller information

- (NSString *)getCurrentCallerInfo {
    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return @"Домофон";
    }
    ensurePJThreadRegistered("CallWaveCallerInfo");
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return @"Домофон";
    }
    return [self displayNameForCaller:stringFromPJString(info.remote_info)];
}

- (NSString *)displayNameForCaller:(NSString *)caller {
    if (caller.length == 0) {
        return @"Домофон";
    }

    NSRange firstQuote = [caller rangeOfString:@"\""];
    if (firstQuote.location != NSNotFound) {
        NSRange searchRange = NSMakeRange(NSMaxRange(firstQuote), caller.length - NSMaxRange(firstQuote));
        NSRange secondQuote = [caller rangeOfString:@"\"" options:0 range:searchRange];
        if (secondQuote.location != NSNotFound) {
            return [caller substringWithRange:NSMakeRange(NSMaxRange(firstQuote),
                                                          secondQuote.location - NSMaxRange(firstQuote))];
        }
    }

    NSRange sip = [caller rangeOfString:@"sip:" options:NSCaseInsensitiveSearch];
    if (sip.location != NSNotFound) {
        NSUInteger start = NSMaxRange(sip);
        NSRange at = [caller rangeOfString:@"@"
                                  options:0
                                    range:NSMakeRange(start, caller.length - start)];
        if (at.location != NSNotFound) {
            return [caller substringWithRange:NSMakeRange(start, at.location - start)];
        }
    }
    return caller;
}

#pragma mark - CallKit

- (void)publishCallState:(CallWaveCallState)state uuid:(NSUUID *)uuid {
    self.callState = state;
    id<CallWaveClientDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(callWaveClient:didChangeCallState:uuid:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate callWaveClient:self didChangeCallState:state uuid:uuid];
        });
    }
}

- (void)setupCallKit {
    if (self.provider != nil) {
        return;
    }

    CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] init];
    configuration.maximumCallGroups = 1;
    configuration.maximumCallsPerCallGroup = 1;
    configuration.supportsVideo = NO;
    configuration.supportedHandleTypes = [NSSet setWithObjects:
                                           @(CXHandleTypeGeneric),
                                           @(CXHandleTypePhoneNumber), nil];
    configuration.includesCallsInRecents = self.configuration.includesCallsInRecents;

    self.provider = [[CXProvider alloc] initWithConfiguration:configuration];
    [self.provider setDelegate:self queue:dispatch_get_main_queue()];
    self.callController = [[CXCallController alloc] init];
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(NSString *)caller
                         forCallId:(pjsua_call_id)callId {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupCallKit];
        NSString *key = uuid.UUIDString;
        if ([self.reportedCallUUIDs containsObject:key]) {
            if (callId != PJSUA_INVALID_ID) {
                [self associateSIPCall:callId withUUID:uuid caller:caller];
            }
            return;
        }

        CXCallUpdate *update = [[CXCallUpdate alloc] init];
        update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric
                                                       value:caller.length > 0 ? caller : @"Домофон"];
        update.localizedCallerName = [self displayNameForCaller:caller];
        update.hasVideo = NO;
        update.supportsHolding = NO;
        update.supportsGrouping = NO;
        update.supportsUngrouping = NO;
        update.supportsDTMF = NO;

        self.activeCalls[key] = @{
            @"call_id": @(callId),
            @"caller": caller.length > 0 ? caller : @"Домофон",
            @"created_at": @([NSDate date].timeIntervalSince1970)
        };
        self.currentCallUUID = uuid;
        self.currentCaller = update.localizedCallerName;
        if (callId != PJSUA_INVALID_ID) {
            self.currentCallIdentifier = callId;
            self.incoming_call_id = callId;
        }
        [self publishCallState:CallWaveCallStateIncoming uuid:uuid];
        [self.reportedCallUUIDs addObject:key];

        [self.provider reportNewIncomingCallWithUUID:uuid
                                              update:update
                                          completion:^(NSError *error) {
            if (error != nil) {
                NSLog(@"CallKit: failed to report incoming call: %@", error);
                [self.activeCalls removeObjectForKey:key];
                [self.reportedCallUUIDs removeObject:key];
                if (callId != PJSUA_INVALID_ID && pjsua_call_is_active(callId)) {
                    pjsua_call_answer(callId, PJSIP_SC_TEMPORARILY_UNAVAILABLE, NULL, NULL);
                }
                [self publishCallState:CallWaveCallStateEnded uuid:uuid];
            } else {
                id<CallWaveClientDelegate> delegate = self.delegate;
                if ([delegate respondsToSelector:@selector(callWaveClient:didReceiveCallFrom:uuid:)]) {
                    [delegate callWaveClient:self
                         didReceiveCallFrom:self.currentCaller ?: @"Домофон"
                                       uuid:uuid];
                }
            }
        }];
    });
}

- (void)associateSIPCall:(pjsua_call_id)callId
                withUUID:(NSUUID *)uuid
                  caller:(NSString *)caller {
    NSString *key = uuid.UUIDString;
    NSMutableDictionary *call = [self.activeCalls[key] mutableCopy] ?: [NSMutableDictionary dictionary];
    call[@"call_id"] = @(callId);
    call[@"caller"] = caller.length > 0 ? caller : @"Домофон";
    self.activeCalls[key] = call;
    self.currentCallUUID = uuid;
    self.currentCaller = [self displayNameForCaller:caller];
    self.currentCallIdentifier = callId;
    self.incoming_call_id = callId;

    CXAnswerCallAction *pending = self.pendingAnswerAction;
    if (pending != nil && [pending.callUUID isEqual:uuid]) {
        self.pendingAnswerAction = nil;
        dispatch_async(self.sipQueue, ^{
            BOOL answered = [self answerSIPCall:callId];
            dispatch_async(dispatch_get_main_queue(), ^{
                answered ? [pending fulfill] : [pending fail];
            });
        });
    }
}

- (void)endCallWithUUID:(NSUUID *)uuid {
    CXEndCallAction *action = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    [self.callController requestTransaction:[[CXTransaction alloc] initWithAction:action]
                                 completion:^(NSError *error) {
        if (error != nil) {
            NSLog(@"CallKit: end transaction failed: %@", error);
        }
    }];
}

- (void)connectedCallWithUUID:(NSUUID *)uuid {
    // Incoming calls are marked connected by fulfilling CXAnswerCallAction.
}

- (NSUUID *)getCurrentCallUUID {
    return self.currentCallUUID;
}

- (pjsua_call_id)callIdForUUID:(NSUUID *)uuid {
    NSNumber *value = self.activeCalls[uuid.UUIDString][@"call_id"];
    return value != nil ? value.intValue : PJSUA_INVALID_ID;
}

- (void)clearCallWithUUID:(NSUUID *)uuid callId:(pjsua_call_id)callId {
    if (uuid != nil) {
        [self.activeCalls removeObjectForKey:uuid.UUIDString];
        [self.reportedCallUUIDs removeObject:uuid.UUIDString];
    }
    if (self.currentCallIdentifier == callId || callId == PJSUA_INVALID_ID) {
        self.currentCallIdentifier = PJSUA_INVALID_ID;
        self.incoming_call_id = PJSUA_INVALID_ID;
        self.currentCallUUID = nil;
        self.microphoneMuted = NO;
    }
}

- (void)providerDidReset:(CXProvider *)provider {
    if (self.currentCallIdentifier != PJSUA_INVALID_ID) {
        [self stopCall];
    }
    [self.activeCalls removeAllObjects];
    [self.reportedCallUUIDs removeAllObjects];
    self.currentCallUUID = nil;
    self.currentCallIdentifier = PJSUA_INVALID_ID;
    self.incoming_call_id = PJSUA_INVALID_ID;
    self.pendingAnswerAction = nil;
    self.microphoneMuted = NO;
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    [action fail];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    pjsua_call_id callId = [self callIdForUUID:action.callUUID];
    if (callId == PJSUA_INVALID_ID) {
        // PushKit may wake the app before the SIP INVITE arrives. Keep the
        // CallKit action pending briefly and complete it once they are paired.
        self.pendingAnswerAction = action;
        [self refreshRegistrationWithError:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (self.pendingAnswerAction == action) {
                self.pendingAnswerAction = nil;
                [action fail];
                [self.provider reportCallWithUUID:action.callUUID
                                      endedAtDate:[NSDate date]
                                           reason:CXCallEndedReasonFailed];
                [self clearCallWithUUID:action.callUUID callId:PJSUA_INVALID_ID];
            }
        });
        return;
    }

    dispatch_async(self.sipQueue, ^{
        BOOL answered = [self answerSIPCall:callId];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (answered) {
                [self publishCallState:CallWaveCallStateConnecting uuid:action.callUUID];
                [action fulfill];
            } else {
                [action fail];
            }
        });
    });
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    pjsua_call_id callId = [self callIdForUUID:action.callUUID];
    self.pendingAnswerAction = nil;
    if (callId != PJSUA_INVALID_ID && gPJSUAStarted) {
        ensurePJThreadRegistered("CallWaveCallKitEnd");
        pjsua_call_hangup(callId, 0, NULL, NULL);
    }
    [self clearCallWithUUID:action.callUUID callId:callId];
    [action fulfill];
    [self publishCallState:CallWaveCallStateEnded uuid:action.callUUID];
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action {
    [self applyMicrophoneMuted:action.muted] ? [action fulfill] : [action fail];
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    self.audioSessionActive = YES;
    dispatch_async(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveCallKitAudio");
        if (gPJSUAStarted) {
            pj_status_t status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                                                   PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
            if (status == PJ_SUCCESS) {
                [self connectMediaForCall:self.currentCallIdentifier];
            } else {
                NSLog(@"Audio: CallKit activation could not open PJSIP device (%d)", status);
            }
        }
    });
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    self.audioSessionActive = NO;
    dispatch_async(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveCallKitAudioOff");
        if (gPJSUAStarted) {
            pjsua_set_no_snd_dev();
        }
    });
}

#pragma mark - PushKit

- (void)registerForVoIPPushes {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pushRegistry == nil) {
            self.pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
            self.pushRegistry.delegate = self;
            self.pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
        }
    });
}

- (void)handleVoIPPushPayload:(NSDictionary *)payload {
    NSDictionary *data = [payload[@"data"] isKindOfClass:NSDictionary.class] ? payload[@"data"] : nil;
    NSString *uuidString = data[@"uuid"] ?: payload[@"uuid"];
    NSUUID *uuid = uuidString.length > 0 ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    if (uuid == nil) {
        uuid = [NSUUID UUID];
    }

    NSString *caller = data[@"callerID"] ?: data[@"caller"] ?: payload[@"caller_id"] ?: @"Домофон";
    [self reportIncomingCallWithUUID:uuid caller:caller forCallId:PJSUA_INVALID_ID];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!gPJSUAStarted || gAccountId == PJSUA_INVALID_ID || !pjsua_acc_is_valid(gAccountId)) {
            NSError *error = nil;
            [self startWithError:&error];
            if (error != nil) {
                NSLog(@"CallWave: start after VoIP push failed: %@", error);
            }
        } else {
            ensurePJThreadRegistered("CallWavePushRegister");
            pjsua_acc_set_registration(gAccountId, PJ_TRUE);
        }
    });
}

- (void)pushRegistry:(PKPushRegistry *)registry
didUpdatePushCredentials:(PKPushCredentials *)pushCredentials
             forType:(PKPushType)type {
    if (![type isEqualToString:PKPushTypeVoIP]) {
        return;
    }
    const unsigned char *bytes = pushCredentials.token.bytes;
    NSMutableString *token = [NSMutableString stringWithCapacity:pushCredentials.token.length * 2];
    for (NSUInteger i = 0; i < pushCredentials.token.length; i++) {
        [token appendFormat:@"%02x", bytes[i]];
    }
    id<CallWaveClientDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(callWaveClient:didUpdateVoIPPushToken:)]) {
        [delegate callWaveClient:self didUpdateVoIPPushToken:token];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry
didInvalidatePushTokenForType:(PKPushType)type {
}

- (void)pushRegistry:(PKPushRegistry *)registry
didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type
withCompletionHandler:(void (^)(void))completion {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        [self handleVoIPPushPayload:payload.dictionaryPayload];
    }
    // handleVoIPPushPayload enqueues reportNewIncomingCall on the main queue.
    // Queue completion after it so PushKit is not acknowledged first.
    dispatch_async(dispatch_get_main_queue(), completion);
}

@end

#pragma mark - PJSUA callbacks

static void onIncomingCall(pjsua_acc_id accId, pjsua_call_id callId, pjsip_rx_data *rdata) {
    CallWaveClient *integration = gActiveClient;
    if (integration == nil) {
        pjsua_call_answer(callId, PJSIP_SC_TEMPORARILY_UNAVAILABLE, NULL, NULL);
        return;
    }

    if (integration.currentCallIdentifier != PJSUA_INVALID_ID &&
        integration.currentCallIdentifier != callId &&
        pjsua_call_is_active(integration.currentCallIdentifier)) {
        pjsua_call_answer(callId, PJSIP_SC_BUSY_HERE, NULL, NULL);
        return;
    }

    integration.currentCallIdentifier = callId;
    integration.incoming_call_id = callId;
    pjsua_call_answer(callId, PJSIP_SC_RINGING, NULL, NULL);

    pjsua_call_info info;
    NSString *caller = @"Домофон";
    if (pjsua_call_get_info(callId, &info) == PJ_SUCCESS) {
        caller = [integration displayNameForCaller:stringFromPJString(info.remote_info)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *uuid = integration.currentCallUUID;
        if (uuid != nil && [integration callIdForUUID:uuid] == PJSUA_INVALID_ID) {
            [integration associateSIPCall:callId withUUID:uuid caller:caller];
        } else {
            [integration reportIncomingCallWithUUID:[NSUUID UUID]
                                            caller:caller
                                         forCallId:callId];
        }
    });
}

static void onCallState(pjsua_call_id callId, pjsip_event *event) {
    PJ_UNUSED_ARG(event);
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return;
    }

    CallWaveClient *integration = gActiveClient;
    if (integration == nil) {
        return;
    }
    if (info.state == PJSIP_INV_STATE_CONFIRMED) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [integration publishCallState:CallWaveCallStateActive
                                     uuid:integration.currentCallUUID];
        });
        return;
    }

    if (info.state != PJSIP_INV_STATE_DISCONNECTED) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *uuid = integration.currentCallUUID;
        if (uuid != nil) {
            [integration.provider reportCallWithUUID:uuid
                                         endedAtDate:[NSDate date]
                                              reason:CXCallEndedReasonRemoteEnded];
        }
        [integration clearCallWithUUID:uuid callId:callId];
        [integration publishCallState:CallWaveCallStateEnded uuid:uuid];
    });
}

static void onCallMediaState(pjsua_call_id callId) {
    CallWaveClient *integration = gActiveClient;
    if (integration == nil) {
        return;
    }
    dispatch_async(integration.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveMedia");
        [integration connectMediaForCall:callId];
    });
}

static void onRegistrationState(pjsua_acc_id accId) {
    pjsua_acc_info info;
    if (pjsua_acc_get_info(accId, &info) != PJ_SUCCESS) {
        return;
    }
    NSLog(@"SIP: registration %d %@", info.status, stringFromPJString(info.status_text));
    dispatch_async(dispatch_get_main_queue(), ^{
        CallWaveClient *client = gActiveClient;
        if (client == nil) {
            return;
        }
        if (info.status == PJSIP_SC_OK && info.expires > 0) {
            client.registrationState = CallWaveRegistrationStateRegistered;
        } else if (info.status >= 300) {
            client.registrationState = CallWaveRegistrationStateFailed;
        } else {
            client.registrationState = CallWaveRegistrationStateRegistering;
        }
        id<CallWaveClientDelegate> delegate = client.delegate;
        if ([delegate respondsToSelector:
                @selector(callWaveClient:didChangeRegistrationState:statusCode:)]) {
            [delegate callWaveClient:client
          didChangeRegistrationState:client.registrationState
                         statusCode:info.status];
        }
    });
}
