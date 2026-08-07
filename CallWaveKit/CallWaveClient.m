#import "CallWaveClient.h"

#import "CallWaveCallRegistry.h"
#import "CallWaveCallStatisticsInternal.h"
#import "CallWaveError.h"
#import "CallWaveEventInternal.h"
#import "CallWaveLogInternal.h"
#import "CallWaveAudioRouteInternal.h"
#import "CallWaveDiagnosticsSnapshotInternal.h"
#import "CallWaveTURNConfiguration.h"
#import "CallWavePushCompletionGate.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CallKit/CallKit.h>
#import <Network/Network.h>
#import <PushKit/PushKit.h>
#import <UIKit/UIKit.h>
#import <pthread.h>
#if __has_include(<PJSIP/pjsua.h>)
#import <PJSIP/pjsua.h>
#else
#import <pjsua.h>
#endif

static NSString *const CallWaveFallbackCallerName = @"Unknown";
static const NSTimeInterval CallWaveAnswerPollInterval = 0.25;
static const NSTimeInterval CallWaveAudioFallbackDelay = 1.5;
static const NSTimeInterval CallWaveDefaultAcceptDelay = 0.5;
static const NSTimeInterval CallWaveMaximumAcceptDelay = 1.0;
static const NSTimeInterval CallWaveDefaultAnswerTimeout = 10.0;
static const NSTimeInterval CallWaveDefaultIncomingCallTimeout = 60.0;
static const NSTimeInterval CallWaveDefaultPushCompletionTimeout = 4.0;
static const NSUInteger CallWaveDTMFDurationMilliseconds = 160;

/// Identifies `sipQueue` from inside a block, so a synchronous hop onto a queue
/// the caller is already running on becomes a plain call instead of a deadlock.
static void *const kCallWaveSIPQueueKey = (void *)&kCallWaveSIPQueueKey;

static pj_bool_t gPJInitialized = PJ_FALSE;
static pj_bool_t gPJSUACreated = PJ_FALSE;
static pj_bool_t gPJSUAStarted = PJ_FALSE;
static pjsua_acc_id gAccountId = PJSUA_INVALID_ID;
/// Backs the REGISTER headers referenced by the current account, so their
/// storage outlives `pjsua_acc_add`.
static pj_pool_t *gAccountHeaderPool = NULL;
static NSUInteger gCreatedTransports = 0;
static __weak CallWaveClient *gActiveClient = nil;

static void onIncomingCall(pjsua_acc_id accId, pjsua_call_id callId, pjsip_rx_data *rdata);
static void onCallState(pjsua_call_id callId, pjsip_event *event);
static void onCallMediaState(pjsua_call_id callId);
static void onRegistrationState(pjsua_acc_id accId);
static void onPJLog(int level, const char *data, int length);

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
        CWLogError(CallWaveLogCategorySIP, @"failed to register thread %s (%d)", name, status);
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

/// `pjsua_acc_info.expires` is `PJSIP_EXPIRES_NOT_SPECIFIED` (0xFFFFFFFF), not
/// zero, once the registration session is gone — which is exactly the state a
/// successful un-REGISTER leaves behind, with `status` still 200. The field is
/// unsigned, so a plain `expires > 0` reports an unregistered account as
/// registered.
static BOOL registrationIsActive(const pjsua_acc_info *info) {
    return info->status == PJSIP_SC_OK &&
           info->expires > 0 &&
           info->expires != PJSIP_EXPIRES_NOT_SPECIFIED;
}

static pj_str_t poolString(pj_pool_t *pool, NSString *value) {
    pj_str_t result;
    pj_strdup2_with_null(pool, &result, value.UTF8String ?: "");
    return result;
}

static pjsip_transport_type_e pjTransportForCallWaveTransport(CallWaveTransport transport) {
    switch (transport) {
        case CallWaveTransportTCP:
            return PJSIP_TRANSPORT_TCP;
        case CallWaveTransportTLS:
            return PJSIP_TRANSPORT_TLS;
        case CallWaveTransportUDP:
            break;
    }
    return PJSIP_TRANSPORT_UDP;
}

static pjsip_transport_type_e pjIPv6TransportForCallWaveTransport(CallWaveTransport transport) {
    switch (transport) {
        case CallWaveTransportTCP:
            return PJSIP_TRANSPORT_TCP6;
        case CallWaveTransportTLS:
            return PJSIP_TRANSPORT_TLS6;
        case CallWaveTransportUDP:
            break;
    }
    return PJSIP_TRANSPORT_UDP6;
}

static pj_turn_tp_type pjTURNTransportForCallWaveTransport(CallWaveTransport transport) {
    switch (transport) {
        case CallWaveTransportTCP: return PJ_TURN_TP_TCP;
        case CallWaveTransportTLS: return PJ_TURN_TP_TLS;
        case CallWaveTransportUDP: return PJ_TURN_TP_UDP;
    }
}

static pjmedia_srtp_use pjSRTPForMediaEncryption(CallWaveMediaEncryption encryption) {
    switch (encryption) {
        case CallWaveMediaEncryptionOptional:
            return PJMEDIA_SRTP_OPTIONAL;
        case CallWaveMediaEncryptionMandatory:
            return PJMEDIA_SRTP_MANDATORY;
        case CallWaveMediaEncryptionDisabled:
            break;
    }
    return PJMEDIA_SRTP_DISABLED;
}

static int pjLogLevelForCallWaveLevel(CallWaveLogLevel level) {
    switch (level) {
        case CallWaveLogLevelOff:     return 0;
        case CallWaveLogLevelError:   return 1;
        case CallWaveLogLevelWarning: return 2;
        case CallWaveLogLevelInfo:    return 3;
        case CallWaveLogLevelDebug:   return 5;
    }
    return 2;
}

/// CallKit wants to know why a call is gone. PJSIP only reports the last SIP
/// status, so the mapping has to guess for anything outside the common set.
static CXCallEndedReason endedReasonForSIPStatus(int status, BOOL wasConnected) {
    if (wasConnected) {
        return CXCallEndedReasonRemoteEnded;
    }
    switch (status) {
        case PJSIP_SC_REQUEST_TIMEOUT:
        case PJSIP_SC_TEMPORARILY_UNAVAILABLE:
        case PJSIP_SC_REQUEST_TERMINATED:
            return CXCallEndedReasonUnanswered;
        case PJSIP_SC_BUSY_HERE:
        case PJSIP_SC_BUSY_EVERYWHERE:
        case PJSIP_SC_DECLINE:
        case PJSIP_SC_OK:
            return CXCallEndedReasonRemoteEnded;
        default:
            return status >= 400 ? CXCallEndedReasonFailed : CXCallEndedReasonRemoteEnded;
    }
}

static void dispatchMain(dispatch_block_t block) {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@interface CallWaveClient () <CXProviderDelegate, PKPushRegistryDelegate>
@property (nonatomic, strong, nullable, readwrite) CallWaveConfiguration *configuration;
@property (nonatomic, copy, readwrite) CallWaveEngineConfiguration *engineConfiguration;
@property (nonatomic, assign, readwrite) CallWaveIntegrationOptions integrationOptions;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign, readwrite) CallWaveRegistrationState registrationState;
@property (nonatomic, strong, nullable, readwrite) NSError *registrationError;
@property (nonatomic, assign, readwrite) CallWaveCallState callState;
@property (nonatomic, copy, nullable, readwrite) NSString *currentCaller;
@property (nonatomic, strong, nullable, readwrite) NSUUID *currentCallUUID;
@property (nonatomic, assign, readwrite) BOOL microphoneMuted;
@property (nonatomic, strong, nullable, readwrite) CXProvider *provider;
@property (nonatomic, strong) CXCallController *callController;
@property (nonatomic, strong) CallWaveCallRegistry *registry;
@property (nonatomic, strong, nullable) PKPushRegistry *pushRegistry;
@property (nonatomic, assign) BOOL audioSessionActive;
@property (nonatomic, assign) BOOL desiredSpeakerEnabled;
@property (nonatomic, strong, readwrite) CallWaveAudioRoute *currentAudioRoute;
@property (nonatomic, strong) dispatch_queue_t sipQueue;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, id> *eventObservers;
@property (nonatomic, strong, nullable) nw_path_monitor_t pathMonitor;
@property (nonatomic, assign) NSUInteger lastPathSignature;
@property (nonatomic, assign) BOOL hasObservedPath;
@property (nonatomic, copy) NSString *networkPathSummary;
@property (nonatomic, assign) NSInteger lastRegistrationSIPStatusCode;
@property (nonatomic, assign) BOOL statisticsSamplingScheduled;

// Visible to the PJSUA C callbacks at the bottom of this file, which sit
// outside the @implementation and therefore need a declared interface.
- (BOOL)managesCallKit;
- (NSString *)displayNameForCaller:(nullable NSString *)caller;
- (BOOL)canAcceptAnotherIncomingCall;
- (nullable CallWaveCall *)takeCallCancelledBeforeInvite;
- (void)handleIncomingSIPCall:(pjsua_call_id)callId caller:(NSString *)caller;
- (void)handleSIPCallConfirmed:(pjsua_call_id)callId;
- (void)handleSIPCallDisconnected:(pjsua_call_id)callId
                        sipStatus:(int)sipStatus
                     wasConnected:(BOOL)wasConnected;
- (void)handleMediaStateForCall:(pjsua_call_id)callId;
- (void)handleRegistrationStatus:(int)status
                          active:(BOOL)active
                          reason:(NSString *)reason;
@end

@implementation CallWaveClient

#pragma mark - Lifecycle

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration {
    return [self initWithConfiguration:configuration
                               options:CallWaveIntegrationOptionManagesEverything
                              provider:nil
                   engineConfiguration:nil];
}

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(CXProvider *)provider {
    return [self initWithConfiguration:configuration
                               options:options
                              provider:provider
                   engineConfiguration:nil];
}

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(CXProvider *)provider
                  engineConfiguration:(CallWaveEngineConfiguration *)engineConfiguration {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _engineConfiguration = [engineConfiguration copy]
            ?: [CallWaveEngineConfiguration defaultConfiguration];
        _integrationOptions = options;
        _registry = [[CallWaveCallRegistry alloc] init];
        _eventObservers = [NSMutableDictionary dictionary];
        _registrationState = CallWaveRegistrationStateStopped;
        _callState = CallWaveCallStateIdle;
        _defaultCallerName = CallWaveFallbackCallerName;
        _answerTimeout = CallWaveDefaultAnswerTimeout;
        _acceptDelay = CallWaveDefaultAcceptDelay;
        _incomingCallTimeout = CallWaveDefaultIncomingCallTimeout;
        _pushCompletionTimeout = CallWaveDefaultPushCompletionTimeout;
        _dtmfMethod = CallWaveDTMFMethodAuto;
        _networkPathSummary = @"unknown";
        _currentAudioRoute = [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance];
        _sipQueue = dispatch_queue_create("com.callwave.pjsip", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_sipQueue, kCallWaveSIPQueueKey, kCallWaveSIPQueueKey, NULL);
        _callController = [[CXCallController alloc] init];
        if (options & CallWaveIntegrationOptionManagesCallKit) {
            [self setupCallKit];
        } else {
            // Host-owned CallKit: the library never creates a second provider
            // and never becomes a provider delegate. It only reports call
            // termination through the injected provider, if there is one.
            _provider = provider;
        }
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidBecomeActive:)
                                                   name:UIApplicationDidBecomeActiveNotification
                                                 object:nil];
        [self observeAudioSessionNotifications];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_pathMonitor != nil) {
        nw_path_monitor_cancel(_pathMonitor);
    }
    if (_running) {
        BOOL ownsRuntime = NO;
        @synchronized (CallWaveClient.class) {
            ownsRuntime = gActiveClient == self;
            if (ownsRuntime) {
                gActiveClient = nil;
            }
        }
        if (ownsRuntime) {
            // Deliberately not `-stop`: a block that captures `self` during
            // dealloc resurrects it. Only globals are touched here.
            [CallWaveClient destroyRuntimeOnQueue:_sipQueue];
        }
    }
}

#pragma mark - Queue helpers

/// Runs `block` on `sipQueue` and waits. Safe to call from `sipQueue` itself.
- (void)performSIPSync:(NS_NOESCAPE dispatch_block_t)block {
    if (dispatch_get_specific(kCallWaveSIPQueueKey) != NULL) {
        block();
        return;
    }
    dispatch_sync(self.sipQueue, block);
}

- (void)performSIPAsync:(dispatch_block_t)block {
    dispatch_async(self.sipQueue, block);
}

#pragma mark - Configuration

- (BOOL)managesCallKit {
    return (self.integrationOptions & CallWaveIntegrationOptionManagesCallKit) != 0;
}

- (void)setLogger:(id<CallWaveLogger>)logger {
    CallWaveLog.logger = logger;
}

- (id<CallWaveLogger>)logger {
    return CallWaveLog.logger;
}

- (void)setDefaultCallerName:(NSString *)defaultCallerName {
    _defaultCallerName = defaultCallerName.length > 0
        ? [defaultCallerName copy]
        : CallWaveFallbackCallerName;
}

- (void)setAcceptDelay:(NSTimeInterval)acceptDelay {
    if (acceptDelay < 0 || isnan(acceptDelay)) {
        acceptDelay = 0;
    } else if (acceptDelay > CallWaveMaximumAcceptDelay) {
        acceptDelay = CallWaveMaximumAcceptDelay;
    }
    _acceptDelay = acceptDelay;
}

- (void)setIncomingCallTimeout:(NSTimeInterval)incomingCallTimeout {
    _incomingCallTimeout = (incomingCallTimeout > 0 && !isnan(incomingCallTimeout))
        ? incomingCallTimeout
        : 0;
}

- (void)setPushCompletionTimeout:(NSTimeInterval)pushCompletionTimeout {
    _pushCompletionTimeout = (pushCompletionTimeout > 0 && !isnan(pushCompletionTimeout))
        ? pushCompletionTimeout
        : CallWaveDefaultPushCompletionTimeout;
}

- (BOOL)validateConfiguration:(CallWaveConfiguration *)configuration
                        error:(NSError **)error {
    if (configuration.host.length > 0 &&
        configuration.username.length > 0 &&
        configuration.password.length > 0) {
        return YES;
    }
    if (error != NULL) {
        *error = CallWaveMakeError(CallWaveErrorInvalidConfiguration,
                                   @"Host, username and password are required.");
    }
    return NO;
}

- (BOOL)validateEngineConfigurationWithError:(NSError **)error {
    CallWaveEngineConfiguration *engine = self.engineConfiguration;
    CallWaveTURNConfiguration *turn = engine.TURNConfiguration;
    BOOL validPolicy = engine.IPVersionPolicy >= CallWaveIPVersionPolicyAutomatic &&
        engine.IPVersionPolicy <= CallWaveIPVersionPolicyIPv6Only;
    BOOL validTURN = turn == nil ||
        (turn.server.length > 0 && turn.username.length > 0 && turn.password.length > 0);
    if (validPolicy && validTURN) {
        return YES;
    }
    if (error != NULL) {
        NSString *message = validPolicy
            ? @"TURN server, username and password are required."
            : @"The IP version policy is invalid.";
        *error = CallWaveMakeError(CallWaveErrorInvalidConfiguration, message);
    }
    return NO;
}

#pragma mark - Engine and account lifecycle

- (BOOL)claimRuntimeWithError:(NSError **)error {
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
    return YES;
}

- (BOOL)startEngineWithError:(NSError **)error {
    if (self.isRunning) {
        return YES;
    }
    if (![self validateEngineConfigurationWithError:error]) {
        return NO;
    }
    if (![self claimRuntimeWithError:error]) {
        return NO;
    }

    CallWaveLog.level = self.engineConfiguration.logLevel;

    __block pj_status_t status = PJ_SUCCESS;
    [self performSIPSync:^{
        status = [self startEngineLocked];
    }];
    if (status != PJ_SUCCESS) {
        @synchronized (CallWaveClient.class) {
            if (gActiveClient == self) {
                gActiveClient = nil;
            }
        }
        if (error != NULL) {
            *error = CallWaveMakeSIPError(status, @"PJSIP start");
        }
        return NO;
    }
    self.running = YES;
    [self startPathMonitorIfNeeded];
    return YES;
}

- (BOOL)startWithError:(NSError **)error {
    CallWaveConfiguration *configuration = self.configuration;
    if (configuration == nil) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorNotConfigured,
                                       @"No configuration. Use -startEngineWithError: "
                                       @"followed by -loginWithConfiguration:completion:.");
        }
        return NO;
    }
    if (![self validateConfiguration:configuration error:error]) {
        return NO;
    }
    if (![self startEngineWithError:error]) {
        self.registrationState = CallWaveRegistrationStateFailed;
        return NO;
    }
    return [self updateConfiguration:configuration error:error];
}

- (void)loginWithConfiguration:(CallWaveConfiguration *)configuration
                    completion:(CallWaveCompletion)completion {
    CallWaveConfiguration *copy = [configuration copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        [self updateConfiguration:copy error:&error];
        [self complete:completion error:error];
    });
}

- (BOOL)updateConfiguration:(CallWaveConfiguration *)configuration
                      error:(NSError **)error {
    if (![self validateConfiguration:configuration error:error]) {
        return NO;
    }
    if (!self.isRunning && ![self startEngineWithError:error]) {
        return NO;
    }

    CallWaveConfiguration *copy = [configuration copy];
    self.registrationState = CallWaveRegistrationStateRegistering;

    __block pj_status_t status = PJ_SUCCESS;
    [self performSIPSync:^{
        status = [self applyConfigurationLocked:copy];
    }];

    if (status != PJ_SUCCESS) {
        NSError *failure = CallWaveMakeSIPError(status, @"SIP account setup");
        self.registrationState = CallWaveRegistrationStateFailed;
        self.registrationError = failure;
        if (error != NULL) {
            *error = failure;
        }
        return NO;
    }

    BOOL recentsChanged = self.configuration.includesCallsInRecents != copy.includesCallsInRecents;
    self.configuration = copy;
    if (recentsChanged && self.managesCallKit) {
        dispatchMain(^{
            [self refreshProviderConfiguration];
        });
    }
    return YES;
}

/// Creates the PJSUA runtime once. Must run on `sipQueue`.
- (pj_status_t)startEngineLocked {
    CallWaveEngineConfiguration *engine = self.engineConfiguration;

    if (!gPJSUACreated) {
        pj_status_t status = pjsua_create();
        if (status != PJ_SUCCESS) {
            return status;
        }
        gPJSUACreated = PJ_TRUE;
        gPJInitialized = PJ_TRUE;
    }

    if (!ensurePJThreadRegistered("CallWaveConfig")) {
        return PJ_EUNKNOWN;
    }

    if (gPJSUAStarted) {
        return PJ_SUCCESS;
    }

    pjsua_config config;
    pjsua_logging_config logging;
    pjsua_media_config media;
    pjsua_config_default(&config);
    pjsua_logging_config_default(&logging);
    pjsua_media_config_default(&media);

    config.max_calls = (unsigned)MIN(engine.maximumCalls, (NSUInteger)PJSUA_MAX_CALLS);
    config.thread_cnt = 1;
    config.cb.on_incoming_call = &onIncomingCall;
    config.cb.on_call_state = &onCallState;
    config.cb.on_call_media_state = &onCallMediaState;
    config.cb.on_reg_state = &onRegistrationState;

    NSString *userAgent = engine.userAgent;
    if (userAgent.length > 0) {
        config.user_agent = pj_str((char *)userAgent.UTF8String);
    }

    NSArray<NSString *> *stunServers = engine.STUNServers;
    if (stunServers.count > 0) {
        NSUInteger count = MIN(stunServers.count, (NSUInteger)(sizeof(config.stun_srv) / sizeof(config.stun_srv[0])));
        for (NSUInteger index = 0; index < count; index++) {
            config.stun_srv[index] = pj_str((char *)stunServers[index].UTF8String);
        }
        config.stun_srv_cnt = (unsigned)count;
    }

    media.thread_cnt = 1;
    media.has_ioqueue = PJ_TRUE;
    media.no_vad = engine.isVoiceActivityDetectionEnabled ? PJ_FALSE : PJ_TRUE;
    media.enable_ice = (engine.isICEEnabled || engine.TURNConfiguration != nil) ? PJ_TRUE : PJ_FALSE;
    media.ec_tail_len = (unsigned)engine.echoCancellationTailMilliseconds;

    CallWaveTURNConfiguration *turn = engine.TURNConfiguration;
    if (turn != nil) {
        media.enable_turn = PJ_TRUE;
        media.turn_server = pj_str((char *)turn.server.UTF8String);
        media.turn_conn_type = pjTURNTransportForCallWaveTransport(turn.transport);
        media.turn_auth_cred.type = PJ_STUN_AUTH_CRED_STATIC;
        media.turn_auth_cred.data.static_cred.realm = pj_str("*");
        media.turn_auth_cred.data.static_cred.username = pj_str((char *)turn.username.UTF8String);
        media.turn_auth_cred.data.static_cred.data_type = PJ_STUN_PASSWD_PLAIN;
        media.turn_auth_cred.data.static_cred.data = pj_str((char *)turn.password.UTF8String);
        CWLogInfo(CallWaveLogCategoryNetwork, @"TURN enabled via transport %ld",
                  (long)turn.transport);
    }

    // Everything PJSIP prints is forwarded to CallWaveLog instead of stdout:
    // at level 4 and above the trace contains whole SIP messages, including
    // the `Authorization` header.
    logging.level = (unsigned)pjLogLevelForCallWaveLevel(engine.logLevel);
    logging.console_level = 0;
    logging.cb = &onPJLog;
    logging.log_filename = pj_str(NULL);

    pj_status_t status = pjsua_init(&config, &logging, &media);
    if (status != PJ_SUCCESS) {
        return status;
    }

    // UDP is created eagerly because it is the default for intercoms; TCP is
    // best effort. Anything else is created on demand by the account.
    status = [self ensureTransportLocked:CallWaveTransportUDP];
    if (status != PJ_SUCCESS) {
        return status;
    }
    pj_status_t tcpStatus = [self ensureTransportLocked:CallWaveTransportTCP];
    if (tcpStatus != PJ_SUCCESS) {
        CWLogWarning(CallWaveLogCategorySIP, @"optional TCP transport unavailable (%d)", tcpStatus);
    }

    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        return status;
    }
    gPJSUAStarted = PJ_TRUE;
    pjsua_set_no_snd_dev();
    [self applyCodecPrioritiesLocked];
    return PJ_SUCCESS;
}

/// Must run on `sipQueue`.
- (void)applyCodecPrioritiesLocked {
    NSArray<NSString *> *codecs = self.engineConfiguration.preferredCodecs;
    if (codecs.count == 0) {
        return;
    }
    for (NSUInteger index = 0; index < codecs.count; index++) {
        NSString *identifier = codecs[index];
        pj_str_t name = pj_str((char *)identifier.UTF8String);
        // 254 down, so anything unlisted keeps PJSIP's own middling priority.
        pj_uint8_t priority = (pj_uint8_t)MAX((NSInteger)254 - (NSInteger)index, (NSInteger)1);
        pj_status_t status = pjsua_codec_set_priority(&name, priority);
        if (status != PJ_SUCCESS) {
            CWLogWarning(CallWaveLogCategorySIP, @"codec %@ not available (%d)", identifier, status);
        }
    }
}

/// Must run on `sipQueue`.
- (pj_status_t)ensureTransportLocked:(CallWaveTransport)transport {
    CallWaveIPVersionPolicy policy = self.engineConfiguration.IPVersionPolicy;
    BOOL needsIPv4 = policy != CallWaveIPVersionPolicyIPv6Only;
    BOOL needsIPv6 = policy != CallWaveIPVersionPolicyIPv4Only;
    pj_status_t ipv4Status = PJ_SUCCESS;
    pj_status_t ipv6Status = PJ_SUCCESS;

    if (needsIPv4) {
        ipv4Status = [self ensureTransportTypeLocked:pjTransportForCallWaveTransport(transport)
                                                   bit:(1u << ((NSUInteger)transport * 2u))
                                             transport:transport];
    }
    if (needsIPv6) {
        ipv6Status = [self ensureTransportTypeLocked:pjIPv6TransportForCallWaveTransport(transport)
                                                   bit:(1u << ((NSUInteger)transport * 2u + 1u))
                                             transport:transport];
    }

    if (policy == CallWaveIPVersionPolicyIPv4Only) return ipv4Status;
    if (policy == CallWaveIPVersionPolicyIPv6Only) return ipv6Status;
    // Automatic is dual stack but remains usable on a single-stack network.
    return ipv4Status == PJ_SUCCESS || ipv6Status == PJ_SUCCESS
        ? PJ_SUCCESS
        : ipv4Status;
}

/// Must run on `sipQueue`.
- (pj_status_t)ensureTransportTypeLocked:(pjsip_transport_type_e)type
                                      bit:(NSUInteger)bit
                                transport:(CallWaveTransport)transport {
    if (gCreatedTransports & bit) {
        return PJ_SUCCESS;
    }
    pjsua_transport_config config;
    pjsua_transport_config_default(&config);
    config.port = 0;
    if (transport == CallWaveTransportTLS) {
        config.tls_setting.method = PJSIP_TLSV1_2_METHOD;
        config.tls_setting.verify_server =
            self.engineConfiguration.verifiesTLSCertificate ? PJ_TRUE : PJ_FALSE;
        if (!self.engineConfiguration.verifiesTLSCertificate) {
            CWLogWarning(CallWaveLogCategorySIP,
                         @"TLS certificate verification is disabled for this engine");
        }
    }
    pj_status_t status = pjsua_transport_create(type, &config, NULL);
    if (status == PJ_SUCCESS) {
        gCreatedTransports |= bit;
    }
    return status;
}

/// Swaps the SIP account in place. The PJSUA runtime is never destroyed, so
/// this is safe to run for every incoming call. Must run on `sipQueue`.
- (pj_status_t)applyConfigurationLocked:(CallWaveConfiguration *)configuration {
    if (!gPJSUAStarted) {
        return PJ_EINVALIDOP;
    }
    if (!ensurePJThreadRegistered("CallWaveAccount")) {
        return PJ_EUNKNOWN;
    }

    BOOL accountValid = gAccountId != PJSUA_INVALID_ID && pjsua_acc_is_valid(gAccountId);
    if (accountValid && [configuration isEqualToConfiguration:self.configuration]) {
        return pjsua_acc_set_registration(gAccountId, PJ_TRUE);
    }

    pj_status_t transportStatus = [self ensureTransportLocked:configuration.transport];
    if (transportStatus != PJ_SUCCESS) {
        return transportStatus;
    }

    if (accountValid) {
        pjsua_acc_set_registration(gAccountId, PJ_FALSE);
        pjsua_acc_del(gAccountId);
        gAccountId = PJSUA_INVALID_ID;
    }
    if (gAccountHeaderPool != NULL) {
        pj_pool_release(gAccountHeaderPool);
        gAccountHeaderPool = NULL;
    }

    NSString *identity = configuration.identityURI;
    NSString *registrar = configuration.registrarURI;
    NSString *authentication = configuration.authenticationUsername;
    NSString *realm = configuration.realm;
    NSString *password = configuration.password;
    NSString *proxy = configuration.outboundProxy;

    pjsua_acc_config account;
    pjsua_acc_config_default(&account);
    account.id = pj_str((char *)identity.UTF8String);
    account.reg_uri = pj_str((char *)registrar.UTF8String);
    account.cred_count = 1;
    account.cred_info[0].scheme = pj_str("digest");
    account.cred_info[0].realm = pj_str((char *)realm.UTF8String);
    account.cred_info[0].username = pj_str((char *)authentication.UTF8String);
    account.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    account.cred_info[0].data = pj_str((char *)password.UTF8String);
    account.reg_timeout = (unsigned)configuration.registrationExpiry;
    account.reg_retry_interval = 5;
    account.reg_retry_random_interval = 2;
    account.ka_interval = (unsigned)configuration.keepAliveInterval;
    account.allow_contact_rewrite = PJ_TRUE;
    account.contact_use_src_port = PJ_TRUE;
    account.use_srtp = pjSRTPForMediaEncryption(configuration.mediaEncryption);
    // SRTP over plain UDP signalling is what an intercom on a LAN offers; do
    // not additionally demand a secure signalling path.
    account.srtp_secure_signaling = 0;

    switch (self.engineConfiguration.IPVersionPolicy) {
        case CallWaveIPVersionPolicyIPv4Only:
            account.ipv6_sip_use = PJSUA_IPV6_DISABLED;
            account.ipv6_media_use = PJSUA_IPV6_DISABLED;
            account.nat64_opt = PJSUA_NAT64_DISABLED;
            break;
        case CallWaveIPVersionPolicyIPv6Only:
            account.ipv6_sip_use = PJSUA_IPV6_ENABLED_USE_IPV6_ONLY;
            account.ipv6_media_use = PJSUA_IPV6_ENABLED_USE_IPV6_ONLY;
            account.nat64_opt = PJSUA_NAT64_ENABLED;
            break;
        case CallWaveIPVersionPolicyAutomatic:
            account.ipv6_sip_use = PJSUA_IPV6_ENABLED_NO_PREFERENCE;
            account.ipv6_media_use = PJSUA_IPV6_ENABLED_NO_PREFERENCE;
            account.nat64_opt = PJSUA_NAT64_ENABLED;
            break;
    }

    if (proxy.length > 0) {
        account.proxy_cnt = 1;
        account.proxy[0] = pj_str((char *)proxy.UTF8String);
        account.reg_use_proxy = PJSUA_REG_USE_ACC_PROXY;
    }

    NSDictionary<NSString *, NSString *> *headers = configuration.additionalRegistrationHeaders;
    if (headers.count > 0) {
        // The header list is referenced, not copied, so its storage has to
        // outlive this function; the pool is released with the account.
        gAccountHeaderPool = pjsua_pool_create("callwave-hdr", 1024, 1024);
        if (gAccountHeaderPool != NULL) {
            pj_list_init(&account.reg_hdr_list);
            for (NSString *name in headers) {
                pj_str_t headerName = poolString(gAccountHeaderPool, name);
                pj_str_t headerValue = poolString(gAccountHeaderPool, headers[name]);
                pjsip_generic_string_hdr *header =
                    pjsip_generic_string_hdr_create(gAccountHeaderPool, &headerName, &headerValue);
                if (header != NULL) {
                    pj_list_push_back(&account.reg_hdr_list, header);
                }
            }
        }
    }

    pj_status_t status = pjsua_acc_add(&account, PJ_TRUE, &gAccountId);
    if (status == PJ_SUCCESS) {
        CWLogInfo(CallWaveLogCategorySIP, @"registration started for %@ via %@",
                  CWRedact(identity), CWRedact(registrar));
    }
    return status;
}

- (BOOL)isRegistered {
    if (!gPJSUAStarted || gAccountId == PJSUA_INVALID_ID) {
        return NO;
    }

    __block BOOL registered = NO;
    [self performSIPSync:^{
        ensurePJThreadRegistered("CallWaveRegistrationCheck");
        if (!pjsua_acc_is_valid(gAccountId)) {
            return;
        }
        pjsua_acc_info info;
        if (pjsua_acc_get_info(gAccountId, &info) == PJ_SUCCESS) {
            registered = registrationIsActive(&info);
        }
    }];
    return registered;
}

- (BOOL)validateAccountWithError:(NSError **)error {
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
    return YES;
}

- (BOOL)setRegistrationEnabled:(BOOL)enabled
                       context:(NSString *)context
                         error:(NSError **)error {
    if (![self validateAccountWithError:error]) {
        return NO;
    }

    __block pj_status_t status = PJ_EUNKNOWN;
    [self performSIPSync:^{
        ensurePJThreadRegistered("CallWaveRegistration");
        status = pjsua_acc_set_registration(gAccountId, enabled ? PJ_TRUE : PJ_FALSE);
    }];
    if (status != PJ_SUCCESS) {
        if (error != NULL) {
            *error = CallWaveMakeSIPError(status, context);
        }
        return NO;
    }
    return YES;
}

- (BOOL)refreshRegistrationWithError:(NSError **)error {
    return [self setRegistrationEnabled:YES context:@"Registration refresh" error:error];
}

/// Sends `REGISTER` with `Expires: 0` and keeps the account, so a later
/// `-refreshRegistrationWithError:` re-registers without rebuilding anything.
- (BOOL)unregisterWithError:(NSError **)error {
    if (![self validateAccountWithError:error]) {
        return NO;
    }

    __block BOOL hasSession = NO;
    [self performSIPSync:^{
        ensurePJThreadRegistered("CallWaveUnregisterCheck");
        pjsua_acc_info info;
        if (pjsua_acc_get_info(gAccountId, &info) == PJ_SUCCESS) {
            hasSession = info.expires != PJSIP_EXPIRES_NOT_SPECIFIED && info.expires > 0;
        }
    }];
    if (!hasSession) {
        // PJSUA answers PJ_EINVALIDOP when there is no session to close, which
        // would turn an unregister-after-every-call into a spurious error.
        self.registrationState = CallWaveRegistrationStateStopped;
        return YES;
    }

    return [self setRegistrationEnabled:NO context:@"Unregister" error:error];
}

- (BOOL)logoutWithError:(NSError **)error {
    if (![self validateAccountWithError:error]) {
        return NO;
    }

    [self performSIPSync:^{
        ensurePJThreadRegistered("CallWaveLogout");
        pjsua_acc_set_registration(gAccountId, PJ_FALSE);
        pjsua_acc_del(gAccountId);
        gAccountId = PJSUA_INVALID_ID;
        if (gAccountHeaderPool != NULL) {
            pj_pool_release(gAccountHeaderPool);
            gAccountHeaderPool = NULL;
        }
    }];
    self.configuration = nil;
    self.registrationState = CallWaveRegistrationStateStopped;
    self.registrationError = nil;
    return YES;
}

+ (void)destroyRuntimeOnQueue:(dispatch_queue_t)queue {
    dispatch_block_t teardown = ^{
        ensurePJThreadRegistered("CallWaveTeardown");
        if (gAccountId != PJSUA_INVALID_ID && pjsua_acc_is_valid(gAccountId)) {
            pjsua_acc_set_registration(gAccountId, PJ_FALSE);
            pjsua_acc_del(gAccountId);
        }
        gAccountId = PJSUA_INVALID_ID;
        if (gAccountHeaderPool != NULL) {
            pj_pool_release(gAccountHeaderPool);
            gAccountHeaderPool = NULL;
        }
        if (gPJSUACreated) {
            pjsua_destroy();
        }
        gPJSUAStarted = PJ_FALSE;
        gPJSUACreated = PJ_FALSE;
        gPJInitialized = PJ_FALSE;
        gCreatedTransports = 0;
    };

    if (dispatch_get_specific(kCallWaveSIPQueueKey) != NULL) {
        teardown();
    } else {
        dispatch_sync(queue, teardown);
    }
}

- (void)stop {
    if (!self.isRunning && gActiveClient != self) {
        return;
    }

    NSArray<CallWaveCall *> *calls = [self.registry removeAllCalls];
    [self performSIPSync:^{
        ensurePJThreadRegistered("CallWaveStop");
        for (CallWaveCall *call in calls) {
            if (call.callId != CallWaveSIPCallIdInvalid && pjsua_call_is_active(call.callId)) {
                pjsua_call_hangup(call.callId, 0, NULL, NULL);
            }
        }
    }];
    // Without this the calls stay on the CallKit call list after the stack is
    // gone, and the user is left looking at a call that cannot be ended.
    dispatchMain(^{
        for (CallWaveCall *call in calls) {
            if (call.state != CallWaveCallStateEnded) {
                [self reportCallEndedWithUUID:call.uuid reason:CXCallEndedReasonFailed];
            }
        }
    });

    if (self.pathMonitor != nil) {
        nw_path_monitor_cancel(self.pathMonitor);
        self.pathMonitor = nil;
        self.hasObservedPath = NO;
    }

    [CallWaveClient destroyRuntimeOnQueue:self.sipQueue];

    self.running = NO;
    self.registrationState = CallWaveRegistrationStateStopped;
    self.registrationError = nil;
    self.callState = CallWaveCallStateIdle;
    self.currentCallUUID = nil;
    self.currentCaller = nil;
    self.microphoneMuted = NO;
    @synchronized (CallWaveClient.class) {
        if (gActiveClient == self) {
            gActiveClient = nil;
        }
    }
}

#pragma mark - Network and application lifecycle

- (void)startPathMonitorIfNeeded {
    if (!self.engineConfiguration.handlesNetworkChanges || self.pathMonitor != nil) {
        return;
    }

    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, self.sipQueue);
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        [weakSelf handleObservedPath:path];
    });
    self.pathMonitor = monitor;
    nw_path_monitor_start(monitor);
}

/// Runs on `sipQueue`.
- (void)handleObservedPath:(nw_path_t)path {
    NSUInteger signature = 0;
    if (nw_path_get_status(path) == nw_path_status_satisfied) {
        signature |= 1u;
        if (nw_path_uses_interface_type(path, nw_interface_type_wifi))     signature |= 1u << 1;
        if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) signature |= 1u << 2;
        if (nw_path_uses_interface_type(path, nw_interface_type_wired))    signature |= 1u << 3;
    }

    BOOL isFirst = !self.hasObservedPath;
    NSUInteger previous = self.lastPathSignature;
    self.hasObservedPath = YES;
    self.lastPathSignature = signature;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ((signature & 1u) == 0) [parts addObject:@"unsatisfied"];
    if (signature & (1u << 1)) [parts addObject:@"wifi"];
    if (signature & (1u << 2)) [parts addObject:@"cellular"];
    if (signature & (1u << 3)) [parts addObject:@"wired"];
    NSString *summary = parts.count > 0 ? [parts componentsJoinedByString:@"+"] : @"other";
    dispatchMain(^{ self.networkPathSummary = summary; });

    if (isFirst || signature == previous || (signature & 1u) == 0) {
        return;
    }

    CWLogInfo(CallWaveLogCategoryNetwork,
              @"network path changed (0x%lx -> 0x%lx), rebuilding transports",
              (unsigned long)previous, (unsigned long)signature);
    [self handleNetworkChangeLocked];
}

- (void)handleNetworkChange {
    [self performSIPAsync:^{
        [self handleNetworkChangeLocked];
    }];
}

/// Must run on `sipQueue`.
- (void)handleNetworkChangeLocked {
    if (!gPJSUAStarted) {
        return;
    }
    ensurePJThreadRegistered("CallWaveNetworkChange");

    pjsua_ip_change_param parameters;
    pjsua_ip_change_param_default(&parameters);
    parameters.restart_listener = PJ_TRUE;

    // Re-registers every account and refreshes the transports, which is what
    // makes the device reachable again after a Wi-Fi to cellular handover.
    pj_status_t status = pjsua_handle_ip_change(&parameters);
    if (status != PJ_SUCCESS) {
        CWLogWarning(CallWaveLogCategoryNetwork, @"IP change handling failed (%d)", status);
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (!self.isRunning || self.registrationState == CallWaveRegistrationStateRegistered) {
        return;
    }
    if (gAccountId == PJSUA_INVALID_ID) {
        return;
    }
    [self performSIPAsync:^{
        ensurePJThreadRegistered("CallWaveForeground");
        if (gPJSUAStarted && gAccountId != PJSUA_INVALID_ID && pjsua_acc_is_valid(gAccountId)) {
            pjsua_acc_set_registration(gAccountId, PJ_TRUE);
        }
    }];
}

#pragma mark - Audio session lifecycle

- (void)observeAudioSessionNotifications {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(audioSessionRouteDidChange:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(audioSessionWasInterrupted:)
                   name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(audioMediaServicesWereReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification object:nil];
}

- (void)publishCurrentAudioRoute {
    dispatchMain(^{
        self.currentAudioRoute =
            [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance];
        CallWaveEvent *event = [CallWaveEvent eventWithType:CallWaveEventTypeAudioRouteChanged];
        event.audioRoute = self.currentAudioRoute;
        [self emitEvent:event];
    });
}

- (void)audioSessionRouteDidChange:(NSNotification *)notification {
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

- (void)audioSessionWasInterrupted:(NSNotification *)notification {
    NSNumber *rawType = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)rawType.unsignedIntegerValue;
    BOOL began = type == AVAudioSessionInterruptionTypeBegan;
    if (began) {
        self.audioSessionActive = NO;
        [self performSIPAsync:^{
            if (gPJSUAStarted) {
                ensurePJThreadRegistered("CallWaveAudioInterrupted");
                pjsua_set_no_snd_dev();
            }
        }];
    } else {
        NSNumber *rawOptions = notification.userInfo[AVAudioSessionInterruptionOptionKey];
        AVAudioSessionInterruptionOptions options = rawOptions.unsignedIntegerValue;
        if ((options & AVAudioSessionInterruptionOptionShouldResume) != 0 && self.registry.count > 0) {
            [self activateAudioSessionWithError:NULL];
        }
    }
    dispatchMain(^{
        CallWaveEvent *event =
            [CallWaveEvent eventWithType:CallWaveEventTypeAudioSessionInterrupted];
        event.audioSessionInterrupted = began;
        [self emitEvent:event];
    });
}

- (void)audioMediaServicesWereReset:(NSNotification *)notification {
    CWLogWarning(CallWaveLogCategoryAudio, @"audio media services were reset");
    self.audioSessionActive = NO;
    [self configureAudioSessionWithError:NULL];
    if (self.registry.count > 0) {
        [self activateAudioSessionWithError:NULL];
    }
    [self publishCurrentAudioRoute];
}

#pragma mark - Events

- (id<NSCopying, NSObject>)addEventObserver:(void (^)(CallWaveEvent *))handler {
    NSUUID *token = [NSUUID UUID];
    if (handler == nil) {
        return token;
    }
    void (^copied)(CallWaveEvent *) = [handler copy];
    dispatchMain(^{
        self.eventObservers[token] = copied;
    });
    return token;
}

- (void)removeEventObserver:(id<NSCopying, NSObject>)token {
    if (![token isKindOfClass:NSUUID.class]) {
        return;
    }
    dispatchMain(^{
        [self.eventObservers removeObjectForKey:(NSUUID *)token];
    });
}

/// Must run on the main queue.
- (void)emitEvent:(CallWaveEvent *)event {
    if (self.eventObservers.count == 0) {
        return;
    }
    for (void (^handler)(CallWaveEvent *) in self.eventObservers.allValues) {
        handler(event);
    }
}

#pragma mark - Call state

- (NSArray<NSUUID *> *)activeCallUUIDs {
    NSArray<CallWaveCall *> *calls = [self.registry.allCalls sortedArrayUsingComparator:
                                      ^NSComparisonResult(CallWaveCall *lhs, CallWaveCall *rhs) {
        return [lhs.createdAt compare:rhs.createdAt];
    }];
    NSMutableArray<NSUUID *> *uuids = [NSMutableArray arrayWithCapacity:calls.count];
    for (CallWaveCall *call in calls) {
        if (call.state == CallWaveCallStateEnded) {
            continue;
        }
        [uuids addObject:call.uuid];
    }
    return uuids;
}

- (CallWaveCallState)stateForCallWithUUID:(NSUUID *)uuid {
    CallWaveCall *call = [self.registry callForUUID:uuid];
    return call != nil ? call.state : CallWaveCallStateIdle;
}

- (NSString *)callerForCallWithUUID:(NSUUID *)uuid {
    return [self.registry callForUUID:uuid].displayName;
}

/// Resolves the UUID an argument-less call action should act on.
- (nullable CallWaveCall *)resolveCallForUUID:(nullable NSUUID *)uuid {
    if (uuid != nil) {
        return [self.registry callForUUID:uuid];
    }
    NSUUID *current = self.currentCallUUID;
    CallWaveCall *call = current != nil ? [self.registry callForUUID:current] : nil;
    return call ?: self.registry.mostRecentCall;
}

/// Must run on the main queue.
- (void)publishCallState:(CallWaveCallState)state forUUID:(NSUUID *)uuid {
    CallWaveCall *call = [self.registry callForUUID:uuid];
    if (call != nil) {
        call.state = state;
        if ([uuid isEqual:self.currentCallUUID] || self.currentCallUUID == nil) {
            self.currentCallUUID = uuid;
            self.currentCaller = call.displayName;
            self.microphoneMuted = call.microphoneMuted;
        }
    }
    self.callState = state;

    id<CallWaveClientDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(callWaveClient:didChangeCallState:uuid:)]) {
        [delegate callWaveClient:self didChangeCallState:state uuid:uuid];
    }

    CallWaveEvent *event = [CallWaveEvent eventWithType:CallWaveEventTypeCallStateChanged];
    event.callUUID = uuid;
    event.callState = state;
    [self emitEvent:event];
    if (state == CallWaveCallStateActive || state == CallWaveCallStateHeld) {
        [self scheduleStatisticsSamplingIfNeeded];
    }
}

/// Must run on the main queue.
- (void)clearCallWithUUID:(nullable NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }
    [self.registry removeCallWithUUID:uuid];
    [self detachCurrentCallIfItIs:uuid];
}

/// Moves `currentCallUUID` off `uuid` without touching the registry, for a call
/// whose record has to outlive the user's decision — a cancellation waiting for
/// its late INVITE. Must run on the main queue.
- (void)detachCurrentCallIfItIs:(nullable NSUUID *)uuid {
    if (uuid == nil || ![uuid isEqual:self.currentCallUUID]) {
        return;
    }
    CallWaveCall *next = self.registry.mostRecentCall;
    self.currentCallUUID = next.uuid;
    self.currentCaller = next.displayName;
    self.microphoneMuted = next != nil ? next.microphoneMuted : NO;
}

#pragma mark - Incoming-only calling

/// Whether the call is still there to be answered. Must run on `sipQueue` or a
/// PJSIP callback thread.
- (BOOL)isCallAnswerable:(pjsua_call_id)callId {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveAnswerCheck");
    if (!pjsua_call_is_active(callId)) {
        return NO;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return NO;
    }
    return info.state == PJSIP_INV_STATE_INCOMING ||
           info.state == PJSIP_INV_STATE_EARLY ||
           info.state == PJSIP_INV_STATE_CONNECTING ||
           info.state == PJSIP_INV_STATE_CONFIRMED;
}

/// Must run on `sipQueue`.
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
    pj_status_t status = pjsua_call_answer2(callId, &settings, PJSIP_SC_OK, NULL, NULL);
    if (status == PJ_SUCCESS) {
        CWLogInfo(CallWaveLogCategoryCall, @"200 OK sent for call %d", callId);
    } else {
        CWLogError(CallWaveLogCategoryCall, @"200 OK failed for call %d (%d)", callId, status);
    }
    return status == PJ_SUCCESS;
}

/// Must run on `sipQueue`.
- (BOOL)rejectSIPCall:(pjsua_call_id)callId withStatus:(pjsip_status_code)statusCode {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveDecline");
    return pjsua_call_answer(callId, statusCode, NULL, NULL) == PJ_SUCCESS;
}

/// Must run on `sipQueue`.
- (BOOL)hangupSIPCall:(pjsua_call_id)callId {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveHangup");
    return pjsua_call_hangup(callId, 0, NULL, NULL) == PJ_SUCCESS;
}

- (void)complete:(CallWaveCompletion)completion error:(NSError *)error {
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    }
}

#pragma mark - Call control through CallKit

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

- (void)setHeld:(BOOL)held completion:(CallWaveCompletion)completion {
    if (self.engineConfiguration.maximumCalls < 2) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorUnsupportedOperation,
                                         @"Hold requires an engine configured for more "
                                         @"than one call.")];
        return;
    }
    NSUUID *uuid = self.currentCallUUID;
    if (uuid == nil || self.callState == CallWaveCallStateIdle) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no call to hold.")];
        return;
    }
    CXSetHeldCallAction *action = [[CXSetHeldCallAction alloc] initWithCallUUID:uuid
                                                                        onHold:held];
    [self requestTransactionWithAction:action completion:completion];
}

#pragma mark - Direct call control

- (void)acceptCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    [self acceptCallWithUUID:uuid timeout:self.answerTimeout completion:completion];
}

- (void)acceptCallWithUUID:(NSUUID *)uuid
                   timeout:(NSTimeInterval)timeout
                completion:(CallWaveCompletion)completion {
    NSDate *startedAt = [NSDate date];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0)];
    dispatchMain(^{
        CallWaveCall *call = [self resolveCallForUUID:uuid];
        NSUUID *target = call.uuid ?: uuid;
        if (target == nil) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to answer.")];
            return;
        }
        // The audio session category must be in place before the answer so the
        // media path is ready when CallKit activates the session.
        [self configureAudioSessionWithError:NULL];
        [self attemptAcceptForUUID:target
                          deadline:deadline
                         startedAt:startedAt
                        completion:completion];
    });
}

/// Runs on the main queue. The INVITE frequently arrives after CallKit has
/// answered, so the call is polled instead of blocking a CallKit action.
- (void)attemptAcceptForUUID:(NSUUID *)uuid
                    deadline:(NSDate *)deadline
                   startedAt:(NSDate *)startedAt
                  completion:(CallWaveCompletion)completion {
    CallWaveCall *call = [self.registry callForUUID:uuid];
    pjsua_call_id callId = call != nil ? call.callId : CallWaveSIPCallIdInvalid;

    NSTimeInterval waitedMilliseconds = -startedAt.timeIntervalSinceNow * 1000.0;

    if (callId == CallWaveSIPCallIdInvalid) {
        if (deadline.timeIntervalSinceNow <= 0) {
            CWLogError(CallWaveLogCategoryCall, @"no INVITE for call %@ after %.0f ms, giving up",
                       uuid.UUIDString, waitedMilliseconds);
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorTimedOut,
                                             @"The SIP INVITE did not arrive in time.")];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(CallWaveAnswerPollInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self attemptAcceptForUUID:uuid
                              deadline:deadline
                             startedAt:startedAt
                            completion:completion];
        });
        return;
    }

    NSTimeInterval settleDelay = self.acceptDelay;
    CWLogInfo(CallWaveLogCategoryCall,
              @"INVITE for call %@ observed after %.0f ms, settle delay %.0f ms",
              uuid.UUIDString, waitedMilliseconds, settleDelay * 1000.0);

    if (settleDelay <= 0) {
        [self answerCall:callId uuid:uuid settleDelay:0 completion:completion];
        return;
    }

    // The settle delay sits outside the INVITE deadline on purpose: an expired
    // deadline stops the wait for the INVITE, it does not cancel a pause that
    // has already begun.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self answerCall:callId uuid:uuid settleDelay:settleDelay completion:completion];
    });
}

/// Runs on the main queue once the settle delay, if any, has elapsed.
- (void)answerCall:(pjsua_call_id)callId
              uuid:(NSUUID *)uuid
       settleDelay:(NSTimeInterval)settleDelay
        completion:(CallWaveCompletion)completion {
    [self performSIPAsync:^{
        // Half a second is long enough for the intercom to cancel the call.
        if (![self isCallAnswerable:callId]) {
            CWLogWarning(CallWaveLogCategoryCall, @"call %@ ended during the %.0f ms settle delay",
                         uuid.UUIDString, settleDelay * 1000.0);
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"The call ended before it could be answered.")];
            return;
        }

        CWLogInfo(CallWaveLogCategoryCall, @"answering call %@ after a %.0f ms settle delay",
                  uuid.UUIDString, settleDelay * 1000.0);
        BOOL answered = [self answerSIPCall:callId];
        dispatchMain(^{
            if (!answered) {
                [self complete:completion
                         error:CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                 @"The SIP call could not be answered.")];
                return;
            }
            [self publishCallState:CallWaveCallStateConnecting forUUID:uuid];
            // Timed from the actual answer, not from the start of the wait.
            [self scheduleAudioSessionFallback];
            [self complete:completion error:nil];
        });
    }];
}

- (void)endCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    [self terminateCallWithUUID:uuid declining:NO completion:completion];
}

- (void)declineCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    [self terminateCallWithUUID:uuid declining:YES completion:completion];
}

- (void)terminateCallWithUUID:(NSUUID *)uuid
                    declining:(BOOL)declining
                   completion:(CallWaveCompletion)completion {
    dispatchMain(^{
        CallWaveCall *call = [self resolveCallForUUID:uuid];
        NSUUID *target = call.uuid ?: uuid;
        pjsua_call_id callId = call != nil ? call.callId : CallWaveSIPCallIdInvalid;
        if (callId == CallWaveSIPCallIdInvalid) {
            // A call the push announced but whose INVITE has not arrived yet.
            // There is nothing to reject through PJSUA, so the rejection is
            // remembered instead and applied to the INVITE when it lands. The
            // user's intent succeeded; this is not an error.
            if ([self.registry markCallCancelledBeforeInvite:target]) {
                CWLogInfo(CallWaveLogCategoryCall,
                          @"call %@ %@ before its INVITE arrived; the INVITE will be refused",
                          target.UUIDString, declining ? @"declined" : @"ended");
                [self publishCallState:CallWaveCallStateEnded forUUID:target];
                [self detachCurrentCallIfItIs:target];
                [self complete:completion error:nil];
                return;
            }
            [self clearCallWithUUID:target];
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             declining ? @"There is no call to decline."
                                                       : @"There is no call to end.")];
            return;
        }

        [self performSIPAsync:^{
            BOOL succeeded = declining
                ? [self rejectSIPCall:callId withStatus:PJSIP_SC_DECLINE]
                : [self hangupSIPCall:callId];
            dispatchMain(^{
                [self publishCallState:CallWaveCallStateEnded forUUID:target];
                [self clearCallWithUUID:target];
                [self complete:completion
                         error:succeeded ? nil
                                         : CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                             declining
                                                                 ? @"The SIP call could not be declined."
                                                                 : @"The SIP call could not be ended.")];
            });
        }];
    });
}

- (BOOL)setMicrophoneMuted:(BOOL)muted error:(NSError **)error {
    CallWaveCall *call = [self resolveCallForUUID:nil];
    if (call == nil || call.callId == CallWaveSIPCallIdInvalid) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorNoActiveCall,
                                       @"There is no call to mute.");
        }
        return NO;
    }

    __block BOOL applied = NO;
    [self performSIPSync:^{
        applied = [self applyMicrophoneMuted:muted toCall:call];
    }];
    if (!applied) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorCallActionFailed,
                                       @"The microphone state could not be changed.");
        }
        return NO;
    }
    dispatchMain(^{
        if ([call.uuid isEqual:self.currentCallUUID]) {
            self.microphoneMuted = muted;
        }
    });
    return YES;
}

- (void)setMicrophoneMuted:(BOOL)muted
           forCallWithUUID:(NSUUID *)uuid
                completion:(CallWaveCompletion)completion {
    dispatchMain(^{
        CallWaveCall *call = [self resolveCallForUUID:uuid];
        if (call == nil || call.callId == CallWaveSIPCallIdInvalid) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to mute.")];
            return;
        }
        [self performSIPAsync:^{
            BOOL applied = [self applyMicrophoneMuted:muted toCall:call];
            dispatchMain(^{
                if (applied && [call.uuid isEqual:self.currentCallUUID]) {
                    self.microphoneMuted = muted;
                }
                [self complete:completion
                         error:applied ? nil
                                       : CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                           @"The microphone state could not "
                                                           @"be changed.")];
            });
        }];
    });
}

- (void)setHeld:(BOOL)held
forCallWithUUID:(NSUUID *)uuid
     completion:(CallWaveCompletion)completion {
    dispatchMain(^{
        CallWaveCall *call = [self resolveCallForUUID:uuid];
        if (call == nil || call.callId == CallWaveSIPCallIdInvalid) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to hold.")];
            return;
        }
        [self performSIPAsync:^{
            BOOL applied = [self applyHold:held toCall:call];
            dispatchMain(^{
                if (applied) {
                    call.onHold = held;
                    [self publishCallState:held ? CallWaveCallStateHeld : CallWaveCallStateActive
                                    forUUID:call.uuid];
                }
                [self complete:completion
                         error:applied ? nil
                                       : CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                           @"The call could not be held.")];
            });
        }];
    });
}

/// Must run on `sipQueue`.
- (BOOL)applyHold:(BOOL)held toCall:(CallWaveCall *)call {
    if (!gPJSUAStarted || call.callId == CallWaveSIPCallIdInvalid) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveHold");
    pj_status_t status = held
        ? pjsua_call_set_hold(call.callId, NULL)
        : pjsua_call_reinvite(call.callId, PJSUA_CALL_UNHOLD, NULL);
    if (status != PJ_SUCCESS) {
        CWLogError(CallWaveLogCategoryCall, @"hold %@ failed for call %d (%d)",
                   held ? @"on" : @"off", call.callId, status);
    }
    return status == PJ_SUCCESS;
}

#pragma mark - Call information

- (CallWaveCallStatistics *)statisticsForCallWithUUID:(NSUUID *)uuid {
    CallWaveCall *call = [self resolveCallForUUID:uuid];
    if (call == nil || call.callId == CallWaveSIPCallIdInvalid) {
        return nil;
    }

    __block CallWaveCallStatistics *statistics = nil;
    [self performSIPSync:^{
        if (!gPJSUAStarted) {
            return;
        }
        ensurePJThreadRegistered("CallWaveStatistics");
        pjsua_call_id callId = call.callId;
        if (!pjsua_call_is_active(callId)) {
            return;
        }

        pjsua_stream_stat stat;
        if (pjsua_call_get_stream_stat(callId, 0, &stat) != PJ_SUCCESS) {
            return;
        }

        NSTimeInterval duration = 0;
        pjsua_call_info info;
        if (pjsua_call_get_info(callId, &info) == PJ_SUCCESS) {
            duration = info.connect_duration.sec + info.connect_duration.msec / 1000.0;
        }

        NSString *codec = nil;
        NSUInteger clockRate = 0;
        pjsua_stream_info streamInfo;
        if (pjsua_call_get_stream_info(callId, 0, &streamInfo) == PJ_SUCCESS &&
            streamInfo.type == PJMEDIA_TYPE_AUDIO) {
            codec = stringFromPJString(streamInfo.info.aud.fmt.encoding_name);
            clockRate = (NSUInteger)streamInfo.info.aud.fmt.clock_rate;
        }

        statistics = [[CallWaveCallStatistics alloc]
                      initWithDuration:duration
                           packetsSent:(NSUInteger)stat.rtcp.tx.pkt
                       packetsReceived:(NSUInteger)stat.rtcp.rx.pkt
                    packetsLostInbound:(NSUInteger)stat.rtcp.rx.loss
                   packetsLostOutbound:(NSUInteger)stat.rtcp.tx.loss
                                jitter:stat.rtcp.rx.jitter.mean / 1000000.0
                         roundTripTime:stat.rtcp.rtt.mean / 1000000.0
                                 codec:codec.length > 0 ? codec : nil
                             clockRate:clockRate];
    }];
    return statistics;
}

- (CallWaveDiagnosticsSnapshot *)diagnosticsSnapshot {
    NSArray<NSUUID *> *calls = self.activeCallUUIDs;
    NSMutableDictionary<NSUUID *, CallWaveCallStatistics *> *statistics =
        [NSMutableDictionary dictionary];
    for (NSUUID *uuid in calls) {
        CallWaveCallStatistics *value = [self statisticsForCallWithUUID:uuid];
        if (value != nil) {
            statistics[uuid] = value;
        }
    }
    return [[CallWaveDiagnosticsSnapshot alloc]
            initWithRunning:self.isRunning
            registrationState:self.registrationState
            registrationSIPStatusCode:self.lastRegistrationSIPStatusCode
            networkPath:self.networkPathSummary ?: @"unknown"
            audioRoute:self.currentAudioRoute ?:
                [CallWaveAudioRoute routeForAudioSession:AVAudioSession.sharedInstance]
            activeCallUUIDs:calls
            callStatistics:statistics];
}

- (void)scheduleStatisticsSamplingIfNeeded {
    NSTimeInterval interval = self.engineConfiguration.statisticsUpdateInterval;
    if (interval <= 0 || self.statisticsSamplingScheduled) {
        return;
    }
    self.statisticsSamplingScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.statisticsSamplingScheduled = NO;
        BOOL hasLiveCall = NO;
        for (NSUUID *uuid in self.activeCallUUIDs) {
            CallWaveCallState state = [self stateForCallWithUUID:uuid];
            if (state != CallWaveCallStateActive && state != CallWaveCallStateHeld) {
                continue;
            }
            hasLiveCall = YES;
            CallWaveCallStatistics *statistics = [self statisticsForCallWithUUID:uuid];
            if (statistics != nil) {
                CallWaveEvent *event =
                    [CallWaveEvent eventWithType:CallWaveEventTypeCallStatisticsUpdated];
                event.callUUID = uuid;
                event.callStatistics = statistics;
                [self emitEvent:event];
            }
        }
        if (hasLiveCall) {
            [self scheduleStatisticsSamplingIfNeeded];
        }
    });
}

+ (NSString *)displayNameForCaller:(NSString *)caller {
    if (caller.length == 0) {
        return @"";
    }

    NSRange firstQuote = [caller rangeOfString:@"\""];
    if (firstQuote.location != NSNotFound) {
        NSRange searchRange = NSMakeRange(NSMaxRange(firstQuote),
                                          caller.length - NSMaxRange(firstQuote));
        NSRange secondQuote = [caller rangeOfString:@"\"" options:0 range:searchRange];
        if (secondQuote.location != NSNotFound) {
            NSString *quoted = [caller substringWithRange:
                                NSMakeRange(NSMaxRange(firstQuote),
                                            secondQuote.location - NSMaxRange(firstQuote))];
            if (quoted.length > 0) {
                return quoted;
            }
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

+ (NSString *)normalizedDTMFDigits:(NSString *)digits {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDabcd*#"];
    });

    NSMutableString *result = [NSMutableString stringWithCapacity:digits.length];
    [digits enumerateSubstringsInRange:NSMakeRange(0, digits.length)
                               options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *substring, NSRange range,
                                         NSRange enclosing, BOOL *stop) {
        if (substring.length == 1 &&
            [allowed characterIsMember:[substring characterAtIndex:0]]) {
            [result appendString:substring.uppercaseString];
        }
    }];
    return result;
}

- (NSString *)displayNameForCaller:(NSString *)caller {
    NSString *name = [CallWaveClient displayNameForCaller:caller];
    return name.length > 0 ? name : self.defaultCallerName;
}

#pragma mark - DTMF

- (void)sendDTMF:(NSString *)digits completion:(CallWaveCompletion)completion {
    [self sendDTMF:digits method:self.dtmfMethod forCallWithUUID:nil completion:completion];
}

- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
      completion:(CallWaveCompletion)completion {
    [self sendDTMF:digits method:method forCallWithUUID:nil completion:completion];
}

- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
 forCallWithUUID:(NSUUID *)uuid
      completion:(CallWaveCompletion)completion {
    NSString *normalized = [CallWaveClient normalizedDTMFDigits:digits ?: @""];
    if (normalized.length == 0) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorInvalidArgument,
                                         @"DTMF digits must be 0-9, A-D, * or #.")];
        return;
    }

    CallWaveCall *call = [self resolveCallForUUID:uuid];
    pjsua_call_id callId = call != nil ? call.callId : CallWaveSIPCallIdInvalid;
    if (!gPJSUAStarted || callId == CallWaveSIPCallIdInvalid) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no call to send DTMF on.")];
        return;
    }

    [self performSIPAsync:^{
        ensurePJThreadRegistered("CallWaveDTMF");
        if (!pjsua_call_is_active(callId)) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"The call is no longer active.")];
            return;
        }

        pj_status_t status = PJ_EINVAL;
        NSString *context = @"DTMF";
        if (method != CallWaveDTMFMethodSIPINFO) {
            context = @"RFC 2833 DTMF";
            status = [self sendDTMFDigits:normalized
                                   callId:callId
                                   method:PJSUA_DTMF_METHOD_RFC2833];
        }
        // A peer that never negotiated telephone-event rejects RFC 2833. SIP
        // INFO is the interoperable fallback intercoms accept.
        if (status != PJ_SUCCESS && method != CallWaveDTMFMethodRFC2833) {
            if (method == CallWaveDTMFMethodAuto) {
                CWLogWarning(CallWaveLogCategoryCall,
                             @"RFC 2833 DTMF failed (%d), retrying with SIP INFO", status);
            }
            context = @"SIP INFO DTMF";
            status = [self sendDTMFDigits:normalized
                                   callId:callId
                                   method:PJSUA_DTMF_METHOD_SIP_INFO];
        }

        [self complete:completion
                 error:status == PJ_SUCCESS ? nil : CallWaveMakeSIPError(status, context)];
    }];
}

/// Must run on `sipQueue` with the thread registered.
- (pj_status_t)sendDTMFDigits:(NSString *)digits
                       callId:(pjsua_call_id)callId
                       method:(pjsua_dtmf_method)method {
    pjsua_call_send_dtmf_param param;
    pjsua_call_send_dtmf_param_default(&param);
    param.method = method;
    param.duration = CallWaveDTMFDurationMilliseconds;
    param.digits = pj_str((char *)digits.UTF8String);
    return pjsua_call_send_dtmf(callId, &param);
}

#pragma mark - Media

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

/// Opens the PJSIP sound device and re-links the conference bridge. Safe to
/// call more than once.
- (void)openSoundDevice {
    self.audioSessionActive = YES;
    [self performSIPAsync:^{
        if (!gPJSUAStarted) {
            return;
        }
        ensurePJThreadRegistered("CallWaveAudio");
        pj_status_t status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                                               PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
        if (status != PJ_SUCCESS) {
            CWLogError(CallWaveLogCategoryAudio, @"PJSIP sound device failed (%d)", status);
            return;
        }
        for (CallWaveCall *call in self.registry.allCalls) {
            [self connectMediaForCall:call];
        }
    }];
}

/// CallKit does not always deliver `-didActivateAudioSession:` — most often on
/// a cold start answered from the lock screen. Activating the session manually
/// a moment later is what keeps two-way audio working.
- (void)scheduleAudioSessionFallback {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(CallWaveAudioFallbackDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.audioSessionActive || self.registry.count == 0) {
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
    [self performSIPAsync:^{
        ensurePJThreadRegistered("CallWaveCallKitAudioOff");
        if (gPJSUAStarted) {
            pjsua_set_no_snd_dev();
        }
    }];
    [self publishCurrentAudioRoute];
}

/// Must run on `sipQueue` or a PJSIP callback thread.
- (void)connectMediaForCall:(CallWaveCall *)call {
    if (!self.audioSessionActive || call.callId == CallWaveSIPCallIdInvalid) {
        return;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(call.callId, &info) != PJ_SUCCESS ||
        info.media_status != PJSUA_CALL_MEDIA_ACTIVE ||
        info.conf_slot == PJSUA_INVALID_ID) {
        return;
    }

    // Remote -> playback is always connected. Capture -> remote is omitted
    // while muted, which produces a real RTP microphone mute.
    pjsua_conf_connect(info.conf_slot, 0);
    if (call.microphoneMuted) {
        pjsua_conf_disconnect(0, info.conf_slot);
    } else {
        pjsua_conf_connect(0, info.conf_slot);
    }
}

/// Must run on `sipQueue`.
- (BOOL)applyMicrophoneMuted:(BOOL)muted toCall:(CallWaveCall *)call {
    call.microphoneMuted = muted;
    if (!gPJSUAStarted || call.callId == CallWaveSIPCallIdInvalid) {
        return YES;
    }

    ensurePJThreadRegistered("CallWaveMute");
    pjsua_call_info info;
    if (pjsua_call_get_info(call.callId, &info) != PJ_SUCCESS ||
        info.conf_slot == PJSUA_INVALID_ID) {
        return NO;
    }

    pj_status_t status = muted
        ? pjsua_conf_disconnect(0, info.conf_slot)
        : pjsua_conf_connect(0, info.conf_slot);
    return status == PJ_SUCCESS;
}

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

#pragma mark - CallKit

- (CXProviderConfiguration *)makeProviderConfiguration {
    CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] init];
    configuration.maximumCallGroups = 1;
    configuration.maximumCallsPerCallGroup = self.engineConfiguration.maximumCalls;
    configuration.supportsVideo = NO;
    configuration.supportedHandleTypes = [NSSet setWithObjects:
                                          @(CXHandleTypeGeneric),
                                          @(CXHandleTypePhoneNumber), nil];
    configuration.includesCallsInRecents = self.configuration.includesCallsInRecents;
    return configuration;
}

- (void)setupCallKit {
    if (self.provider != nil || !self.managesCallKit) {
        return;
    }
    self.provider = [[CXProvider alloc] initWithConfiguration:[self makeProviderConfiguration]];
    [self.provider setDelegate:self queue:dispatch_get_main_queue()];
}

/// `includesCallsInRecents` arrives with the account, which in a per-push setup
/// is later than the provider. Must run on the main queue.
- (void)refreshProviderConfiguration {
    if (!self.managesCallKit || self.provider == nil) {
        return;
    }
    self.provider.configuration = [self makeProviderConfiguration];
}

/// Called from a PJSIP callback thread, like `-canAcceptAnotherIncomingCall`:
/// the registry has its own lock, and a `180`/`603` cannot afford a queue hop.
///
/// The cancellation is honoured for `answerTimeout` — the same budget the
/// client gives an INVITE to arrive — so it cannot outlive the call it belongs
/// to and reject a later, unrelated one.
- (CallWaveCall *)takeCallCancelledBeforeInvite {
    return [self.registry takeCallCancelledBeforeInviteWithin:self.answerTimeout];
}

- (BOOL)canAcceptAnotherIncomingCall {
    if ([self.registry callAwaitingInvite] != nil) {
        return YES;
    }
    NSUInteger live = 0;
    for (CallWaveCall *call in self.registry.allCalls) {
        if (call.state != CallWaveCallStateEnded) {
            live++;
        }
    }
    return live < self.engineConfiguration.maximumCalls;
}

/// A call that arrived as an INVITE under a UUID CallWaveKit invented, before
/// the host reported its own UUID to CallKit. Must run on the main queue.
- (nullable CallWaveCall *)orphanedSIPCallExcludingUUID:(NSUUID *)uuid {
    for (CallWaveCall *call in self.registry.allCalls) {
        if (call.callId != CallWaveSIPCallIdInvalid &&
            !call.reportedToCallKit &&
            call.state != CallWaveCallStateEnded &&
            ![call.uuid isEqual:uuid]) {
            return call;
        }
    }
    return nil;
}

- (void)prepareIncomingCallWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    if (uuid == nil) {
        return;
    }
    NSString *resolved = caller.length > 0 ? caller : self.defaultCallerName;
    dispatchMain(^{
        CallWaveCall *call = [self.registry registerCallWithUUID:uuid];
        if (call.isCancelledBeforeInvite) {
            return;
        }
        call.caller = resolved;
        call.displayName = [self displayNameForCaller:resolved];
        call.reportedToCallKit = YES;
        if (call.callId == CallWaveSIPCallIdInvalid) {
            // The INVITE may have beaten the host's report, in which case
            // `-handleIncomingSIPCall:caller:` already made a call of its own
            // under a UUID CallKit knows nothing about. Adopt its call id.
            CallWaveCall *orphan = [self orphanedSIPCallExcludingUUID:uuid];
            if (orphan != nil) {
                [self.registry bindCallId:orphan.callId toUUID:uuid];
                [self.registry removeCallWithUUID:orphan.uuid];
            }
        }
        self.currentCallUUID = uuid;
        self.currentCaller = call.displayName;
        [self publishCallState:CallWaveCallStateIncoming forUUID:uuid];
        [self configureAudioSessionWithError:NULL];
        [self scheduleIncomingCallTimeoutForUUID:uuid];
    });
    [self wakeRegistration];
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(NSString *)caller
                        completion:(CallWaveCompletion)completion {
    if (!self.managesCallKit) {
        // Host-owned CallKit: the host has already reported the call and owns
        // the PushKit completion handler.
        [self prepareIncomingCallWithUUID:uuid caller:caller];
        [self complete:completion error:nil];
        return;
    }
    [self reportIncomingCallWithUUID:uuid
                              caller:caller
                           forCallId:CallWaveSIPCallIdInvalid
                          completion:completion];
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(NSString *)caller
                         forCallId:(pjsua_call_id)callId
                        completion:(CallWaveCompletion)completion {
    NSString *resolved = caller.length > 0 ? caller : self.defaultCallerName;
    dispatchMain(^{
        [self setupCallKit];
        if (self.provider == nil) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorCallActionFailed,
                                             @"No CXProvider to report the call on.")];
            return;
        }

        CallWaveCall *call = [self.registry registerCallWithUUID:uuid];
        if (call.isCancelledBeforeInvite) {
            if (callId != CallWaveSIPCallIdInvalid) {
                [self performSIPAsync:^{
                    [self rejectSIPCall:callId withStatus:PJSIP_SC_DECLINE];
                }];
            }
            [self complete:completion error:nil];
            return;
        }
        call.caller = resolved;
        call.displayName = [self displayNameForCaller:resolved];
        if (callId != CallWaveSIPCallIdInvalid) {
            [self.registry bindCallId:callId toUUID:uuid];
        }
        self.currentCallUUID = uuid;
        self.currentCaller = call.displayName;

        if (call.reportedToCallKit) {
            [self complete:completion error:nil];
            return;
        }
        call.reportedToCallKit = YES;

        CXCallUpdate *update = [[CXCallUpdate alloc] init];
        update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric
                                                       value:resolved];
        update.localizedCallerName = call.displayName;
        update.hasVideo = NO;
        update.supportsHolding = self.engineConfiguration.maximumCalls > 1;
        update.supportsGrouping = NO;
        update.supportsUngrouping = NO;
        // Door openers are DTMF, so the call must advertise DTMF support.
        update.supportsDTMF = YES;

        [self publishCallState:CallWaveCallStateIncoming forUUID:uuid];
        [self configureAudioSessionWithError:NULL];

        [self.provider reportNewIncomingCallWithUUID:uuid
                                              update:update
                                          completion:^(NSError *error) {
            if (error != nil) {
                CWLogError(CallWaveLogCategoryCall, @"failed to report incoming call: %@", error);
                pjsua_call_id boundId = call.callId;
                [self.registry removeCallWithUUID:uuid];
                if (boundId != CallWaveSIPCallIdInvalid) {
                    [self performSIPAsync:^{
                        [self rejectSIPCall:boundId withStatus:PJSIP_SC_TEMPORARILY_UNAVAILABLE];
                    }];
                }
                [self publishCallState:CallWaveCallStateEnded forUUID:uuid];
            } else {
                [self scheduleIncomingCallTimeoutForUUID:uuid];
                id<CallWaveClientDelegate> delegate = self.delegate;
                if ([delegate respondsToSelector:@selector(callWaveClient:didReceiveCallFrom:uuid:)]) {
                    [delegate callWaveClient:self
                          didReceiveCallFrom:call.displayName
                                        uuid:uuid];
                }
                CallWaveEvent *event = [CallWaveEvent eventWithType:CallWaveEventTypeIncomingCall];
                event.callUUID = uuid;
                event.caller = call.displayName;
                event.callState = CallWaveCallStateIncoming;
                [self emitEvent:event];
            }
            // Only now may a PushKit completion handler run.
            if (completion != nil) {
                completion(error);
            }
        }];
    });
}

- (void)handleCancelledIncomingCallWithUUID:(NSUUID *)uuid
                                      reason:(CXCallEndedReason)reason
                                  completion:(CallWaveCompletion)completion {
    if (uuid == nil) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorInvalidArgument,
                                         @"A call UUID is required.")];
        return;
    }
    dispatchMain(^{
        CallWaveCall *call = [self.registry callForUUID:uuid];
        if (call != nil && call.state == CallWaveCallStateEnded) {
            // Cancellation pushes are intentionally idempotent: the server may
            // retry one after the SIP callback already removed the call.
            [self complete:completion error:nil];
            return;
        }
        if (call == nil) {
            // A cancellation push can overtake the announcement push. Keep a
            // tombstone so neither that push nor its late INVITE can ring.
            call = [self.registry registerCallWithUUID:uuid];
        }
        if (call.callId == CallWaveSIPCallIdInvalid) {
            [self.registry markCallCancelledBeforeInvite:uuid];
        } else {
            pjsua_call_id callId = call.callId;
            [self performSIPAsync:^{
                [self rejectSIPCall:callId withStatus:PJSIP_SC_DECLINE];
            }];
        }
        CWLogInfo(CallWaveLogCategoryPush, @"incoming call %@ was retracted by the server",
                  uuid.UUIDString);
        [self reportCallEndedWithUUID:uuid reason:reason];
        [self publishCallState:CallWaveCallStateEnded forUUID:uuid];
        if (call.callId == CallWaveSIPCallIdInvalid) {
            // Keep the cancelled record until a late INVITE is refused.
            call.state = CallWaveCallStateEnded;
            [self detachCurrentCallIfItIs:uuid];
        } else {
            [self clearCallWithUUID:uuid];
        }
        [self complete:completion error:nil];
    });
}

/// Must run on the main queue.
- (void)scheduleIncomingCallTimeoutForUUID:(NSUUID *)uuid {
    NSTimeInterval timeout = self.incomingCallTimeout;
    if (timeout <= 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CallWaveCall *call = [self.registry callForUUID:uuid];
        if (call == nil || call.state != CallWaveCallStateIncoming) {
            return;
        }
        CWLogInfo(CallWaveLogCategoryCall, @"call %@ rang for %.0fs without an answer",
                  uuid.UUIDString, timeout);
        pjsua_call_id callId = call.callId;
        if (callId != CallWaveSIPCallIdInvalid) {
            [self performSIPAsync:^{
                [self rejectSIPCall:callId withStatus:PJSIP_SC_TEMPORARILY_UNAVAILABLE];
            }];
        }
        [self reportCallEndedWithUUID:uuid reason:CXCallEndedReasonUnanswered];
        [self publishCallState:CallWaveCallStateEnded forUUID:uuid];
        [self clearCallWithUUID:uuid];
    });
}

/// Reports termination through whichever provider exists and always tells the
/// delegate, so a host that kept its provider private can report it itself.
/// Must run on the main queue.
- (void)reportCallEndedWithUUID:(NSUUID *)uuid reason:(CXCallEndedReason)reason {
    if (uuid == nil) {
        return;
    }
    [self.provider reportCallWithUUID:uuid endedAtDate:[NSDate date] reason:reason];
    id<CallWaveClientDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(callWaveClient:didEndCallWithUUID:reason:)]) {
        [delegate callWaveClient:self didEndCallWithUUID:uuid reason:reason];
    }
    CallWaveEvent *event = [CallWaveEvent eventWithType:CallWaveEventTypeCallEnded];
    event.callUUID = uuid;
    event.callState = CallWaveCallStateEnded;
    event.endedReason = reason;
    [self emitEvent:event];
}

- (void)providerDidReset:(CXProvider *)provider {
    NSArray<CallWaveCall *> *calls = [self.registry removeAllCalls];
    [self performSIPAsync:^{
        for (CallWaveCall *call in calls) {
            [self hangupSIPCall:call.callId];
        }
    }];
    self.currentCallUUID = nil;
    self.currentCaller = nil;
    self.microphoneMuted = NO;
    self.callState = CallWaveCallStateIdle;
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    // CallWaveKit is an incoming-only client.
    [action fail];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    // CallKit kills an action that is not fulfilled within a few seconds, while
    // the INVITE routinely arrives later than the push. Fulfil first, then wait
    // for the call and report a failure through the provider if it never comes.
    [action fulfill];
    [self acceptCallWithUUID:action.callUUID completion:^(NSError *error) {
        if (error == nil) {
            return;
        }
        CWLogError(CallWaveLogCategoryCall, @"answering failed: %@", error);
        [self reportCallEndedWithUUID:action.callUUID reason:CXCallEndedReasonFailed];
        [self publishCallState:CallWaveCallStateEnded forUUID:action.callUUID];
        [self clearCallWithUUID:action.callUUID];
    }];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    CallWaveCall *call = [self.registry callForUUID:action.callUUID];
    pjsua_call_id callId = call != nil ? call.callId : CallWaveSIPCallIdInvalid;
    BOOL ringing = call != nil && call.state == CallWaveCallStateIncoming;
    if (callId != CallWaveSIPCallIdInvalid) {
        [self performSIPAsync:^{
            // A call the user rejected while it was ringing gets `603 Decline`;
            // an established one gets BYE.
            if (ringing) {
                [self rejectSIPCall:callId withStatus:PJSIP_SC_DECLINE];
            } else {
                [self hangupSIPCall:callId];
            }
        }];
    }
    [action fulfill];
    [self publishCallState:CallWaveCallStateEnded forUUID:action.callUUID];
    [self clearCallWithUUID:action.callUUID];
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action {
    CallWaveCall *call = [self.registry callForUUID:action.callUUID];
    if (call == nil) {
        [action fail];
        return;
    }
    [self performSIPAsync:^{
        BOOL applied = [self applyMicrophoneMuted:action.muted toCall:call];
        dispatchMain(^{
            if (applied && [call.uuid isEqual:self.currentCallUUID]) {
                self.microphoneMuted = action.muted;
            }
            applied ? [action fulfill] : [action fail];
        });
    }];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
    CallWaveCall *call = [self.registry callForUUID:action.callUUID];
    if (call == nil) {
        [action fail];
        return;
    }
    [self performSIPAsync:^{
        BOOL applied = [self applyHold:action.onHold toCall:call];
        dispatchMain(^{
            if (applied) {
                call.onHold = action.onHold;
                [self publishCallState:action.onHold ? CallWaveCallStateHeld
                                                     : CallWaveCallStateActive
                                forUUID:call.uuid];
                [action fulfill];
            } else {
                [action fail];
            }
        });
    }];
}

- (void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action {
    [self sendDTMF:action.digits
            method:self.dtmfMethod
   forCallWithUUID:action.callUUID
        completion:^(NSError *error) {
        error == nil ? [action fulfill] : [action fail];
    }];
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    [self audioSessionDidActivate:audioSession];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    [self audioSessionDidDeactivate:audioSession];
}

#pragma mark - PJSIP callback handling

- (void)handleIncomingSIPCall:(pjsua_call_id)callId caller:(NSString *)caller {
    dispatchMain(^{
        CallWaveCall *pending = [self.registry callAwaitingInvite];
        if (pending != nil) {
            // The push already created the CallKit call; bind the INVITE to it.
            [self.registry bindCallId:callId toUUID:pending.uuid];
            if (pending.caller.length == 0 || [pending.caller isEqualToString:self.defaultCallerName]) {
                pending.caller = caller;
                pending.displayName = [self displayNameForCaller:caller];
            }
            self.currentCallUUID = pending.uuid;
            self.currentCaller = pending.displayName;
            [self publishCallState:CallWaveCallStateIncoming forUUID:pending.uuid];
            return;
        }

        NSUUID *uuid = [NSUUID UUID];
        if (self.managesCallKit) {
            [self reportIncomingCallWithUUID:uuid caller:caller forCallId:callId completion:nil];
            return;
        }

        // Host-owned CallKit and no push arrived first: track the call so the
        // host can still drive it, and let the delegate decide what to report.
        CallWaveCall *call = [self.registry registerCallWithUUID:uuid];
        call.caller = caller;
        call.displayName = [self displayNameForCaller:caller];
        [self.registry bindCallId:callId toUUID:uuid];
        self.currentCallUUID = uuid;
        self.currentCaller = call.displayName;
        [self publishCallState:CallWaveCallStateIncoming forUUID:uuid];
        id<CallWaveClientDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(callWaveClient:didReceiveCallFrom:uuid:)]) {
            [delegate callWaveClient:self didReceiveCallFrom:call.displayName uuid:uuid];
        }
        [self scheduleIncomingCallTimeoutForUUID:uuid];
    });
}

- (void)handleSIPCallConfirmed:(pjsua_call_id)callId {
    CallWaveCall *call = [self.registry callForCallId:callId];
    if (call == nil) {
        return;
    }
    dispatchMain(^{
        [self publishCallState:call.onHold ? CallWaveCallStateHeld : CallWaveCallStateActive
                       forUUID:call.uuid];
    });
}

- (void)handleSIPCallDisconnected:(pjsua_call_id)callId
                        sipStatus:(int)sipStatus
                     wasConnected:(BOOL)wasConnected {
    CallWaveCall *call = [self.registry callForCallId:callId];
    if (call == nil) {
        return;
    }
    NSUUID *uuid = call.uuid;
    CXCallEndedReason reason = endedReasonForSIPStatus(sipStatus, wasConnected);
    dispatchMain(^{
        [self reportCallEndedWithUUID:uuid reason:reason];
        [self publishCallState:CallWaveCallStateEnded forUUID:uuid];
        [self clearCallWithUUID:uuid];
    });
}

- (void)handleMediaStateForCall:(pjsua_call_id)callId {
    CallWaveCall *call = [self.registry callForCallId:callId];
    if (call == nil) {
        return;
    }
    [self performSIPAsync:^{
        ensurePJThreadRegistered("CallWaveMedia");
        [self connectMediaForCall:call];
    }];
}

- (void)handleRegistrationStatus:(int)status
                          active:(BOOL)active
                          reason:(NSString *)reason {
    dispatchMain(^{
        CallWaveRegistrationState state;
        NSError *error = nil;
        if (active) {
            state = CallWaveRegistrationStateRegistered;
        } else if (status >= 300) {
            state = CallWaveRegistrationStateFailed;
            error = CallWaveMakeSIPStatusError(status, reason, @"SIP registration");
        } else if (status == PJSIP_SC_OK) {
            // 200 with no registration session left: the un-REGISTER succeeded.
            state = CallWaveRegistrationStateStopped;
        } else {
            state = CallWaveRegistrationStateRegistering;
        }
        self.registrationState = state;
        self.registrationError = error;
        self.lastRegistrationSIPStatusCode = status;

        id<CallWaveClientDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:
                @selector(callWaveClient:didChangeRegistrationState:statusCode:)]) {
            [delegate callWaveClient:self didChangeRegistrationState:state statusCode:status];
        }

        CallWaveEvent *event =
            [CallWaveEvent eventWithType:CallWaveEventTypeRegistrationStateChanged];
        event.registrationState = state;
        event.statusCode = status;
        event.error = error;
        [self emitEvent:event];
    });
}

#pragma mark - PushKit

- (void)registerForVoIPPushes {
    if ((self.integrationOptions & CallWaveIntegrationOptionManagesVoIPPushRegistry) == 0) {
        // The host owns the only PKPushRegistry in the process.
        return;
    }
    dispatchMain(^{
        if (self.pushRegistry == nil) {
            self.pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
            self.pushRegistry.delegate = self;
            self.pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
        }
    });
}

/// Re-registers so the intercom's INVITE can reach the device, without
/// recreating the stack.
- (void)wakeRegistration {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!gPJSUAStarted || gAccountId == PJSUA_INVALID_ID || !pjsua_acc_is_valid(gAccountId)) {
            NSError *error = nil;
            if (![self startWithError:&error] && error != nil) {
                CWLogError(CallWaveLogCategoryPush, @"start after VoIP push failed: %@", error);
            }
            return;
        }
        [self performSIPSync:^{
            ensurePJThreadRegistered("CallWavePushRegister");
            pjsua_acc_set_registration(gAccountId, PJ_TRUE);
        }];
    });
}

- (void)handleVoIPPushPayload:(NSDictionary *)payload {
    [self handleVoIPPushPayload:payload completion:nil];
}

- (CallWaveIncomingCallDescriptor *)descriptorForPushPayload:(NSDictionary *)payload {
    CallWavePushPayloadParser parser = self.pushPayloadParser;
    if (parser != nil) {
        CallWaveIncomingCallDescriptor *descriptor = parser(payload ?: @{});
        if (descriptor != nil) {
            return descriptor;
        }
    }

    NSDictionary *data = [payload[@"data"] isKindOfClass:NSDictionary.class] ? payload[@"data"] : nil;
    NSString *uuidString = data[@"uuid"] ?: payload[@"uuid"];
    NSUUID *uuid = uuidString.length > 0 ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    NSString *caller = data[@"callerID"] ?: data[@"caller"] ?: payload[@"caller_id"];
    return [CallWaveIncomingCallDescriptor descriptorWithUUID:uuid ?: [NSUUID UUID]
                                                       caller:caller];
}

- (void)handleVoIPPushPayload:(NSDictionary *)payload
                   completion:(void (^)(void))completion {
    CallWaveIncomingCallDescriptor *descriptor = [self descriptorForPushPayload:payload];

    // PushKit terminates the process with 0xBAADCA11 if its completion handler
    // runs before CallKit has accepted the call — and iOS eventually stops
    // delivering pushes to an application that never runs it at all. It is
    // therefore invoked from inside the report completion, exactly once, and
    // unconditionally once `pushCompletionTimeout` has elapsed.
    CallWavePushCompletionGate *gate =
        [[CallWavePushCompletionGate alloc] initWithCompletion:completion];
    void (^acknowledge)(NSString *) = ^(NSString *why) {
        if ([gate finish]) {
            CWLogInfo(CallWaveLogCategoryPush, @"acknowledging VoIP push (%@)", why);
        }
    };

    dispatchMain(^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(self.pushCompletionTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            acknowledge(@"deadline");
        });

        [self reportIncomingCallWithUUID:descriptor.uuid
                                  caller:descriptor.caller
                              completion:^(NSError *error) {
            dispatchMain(^{
                acknowledge(error == nil ? @"CallKit accepted the call" : @"CallKit refused the call");
            });
        }];
        [self wakeRegistration];
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
    CallWaveEvent *event = [CallWaveEvent eventWithType:CallWaveEventTypeVoIPPushTokenUpdated];
    event.pushToken = token;
    [self emitEvent:event];
}

- (void)pushRegistry:(PKPushRegistry *)registry
didInvalidatePushTokenForType:(PKPushType)type {
    if (![type isEqualToString:PKPushTypeVoIP]) {
        return;
    }
    dispatchMain(^{
        id<CallWaveClientDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:
                @selector(callWaveClientDidInvalidateVoIPPushToken:)]) {
            [delegate callWaveClientDidInvalidateVoIPPushToken:self];
        }
        CallWaveEvent *event =
            [CallWaveEvent eventWithType:CallWaveEventTypeVoIPPushTokenInvalidated];
        [self emitEvent:event];
    });
}

- (void)pushRegistry:(PKPushRegistry *)registry
didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type
withCompletionHandler:(void (^)(void))completion {
    if (![type isEqualToString:PKPushTypeVoIP]) {
        completion();
        return;
    }
    [self handleVoIPPushPayload:payload.dictionaryPayload completion:completion];
}

@end

#pragma mark - PJSUA callbacks

// These run on PJSIP's own worker threads. They may talk to PJSUA directly —
// a `180 Ringing` that waits for a queue hop arrives too late — but every piece
// of CallWaveKit state they touch goes through the lock-protected registry or
// is handed to the main queue.

static void onIncomingCall(pjsua_acc_id accId, pjsua_call_id callId, pjsip_rx_data *rdata) {
    PJ_UNUSED_ARG(accId);
    PJ_UNUSED_ARG(rdata);

    CallWaveClient *client = gActiveClient;
    if (client == nil) {
        pjsua_call_answer(callId, PJSIP_SC_TEMPORARILY_UNAVAILABLE, NULL, NULL);
        return;
    }

    // The user may have rejected this call from the CallKit screen before its
    // INVITE arrived — the push routinely beats the INVITE by a second or more.
    // The peer is still waiting for a final response, so answer one now instead
    // of ringing: `603` here, never CANCEL, because this side is the callee.
    CallWaveCall *cancelled = [client takeCallCancelledBeforeInvite];
    if (cancelled != nil) {
        pjsua_call_answer(callId, PJSIP_SC_DECLINE, NULL, NULL);
        CWLogInfo(CallWaveLogCategoryCall,
                  @"INVITE for call %@ arrived after the user rejected it; answered 603",
                  cancelled.uuid.UUIDString);
        return;
    }

    if (![client canAcceptAnotherIncomingCall]) {
        pjsua_call_answer(callId, PJSIP_SC_BUSY_HERE, NULL, NULL);
        return;
    }

    pjsua_call_answer(callId, PJSIP_SC_RINGING, NULL, NULL);

    pjsua_call_info info;
    NSString *caller = @"";
    if (pjsua_call_get_info(callId, &info) == PJ_SUCCESS) {
        caller = stringFromPJString(info.remote_info);
    }
    [client handleIncomingSIPCall:callId caller:caller];
}

static void onCallState(pjsua_call_id callId, pjsip_event *event) {
    PJ_UNUSED_ARG(event);

    CallWaveClient *client = gActiveClient;
    if (client == nil) {
        return;
    }

    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return;
    }

    if (info.state == PJSIP_INV_STATE_CONFIRMED) {
        [client handleSIPCallConfirmed:callId];
        return;
    }
    if (info.state != PJSIP_INV_STATE_DISCONNECTED) {
        return;
    }

    // `connect_duration` is only non-zero once the call was actually up, which
    // is what separates "the other side hung up" from "it never answered".
    BOOL wasConnected = info.connect_duration.sec > 0 || info.connect_duration.msec > 0;
    [client handleSIPCallDisconnected:callId
                            sipStatus:(int)info.last_status
                         wasConnected:wasConnected];
}

static void onCallMediaState(pjsua_call_id callId) {
    [gActiveClient handleMediaStateForCall:callId];
}

static void onRegistrationState(pjsua_acc_id accId) {
    pjsua_acc_info info;
    if (pjsua_acc_get_info(accId, &info) != PJ_SUCCESS) {
        return;
    }
    NSString *reason = stringFromPJString(info.status_text);
    CWLogInfo(CallWaveLogCategorySIP, @"registration %d %@", (int)info.status, reason);
    [gActiveClient handleRegistrationStatus:(int)info.status
                                     active:registrationIsActive(&info)
                                     reason:reason];
}

static void onPJLog(int level, const char *data, int length) {
    if (data == NULL || length <= 0) {
        return;
    }
    CallWaveLogLevel mapped = CallWaveLogLevelDebug;
    if (level <= 1) {
        mapped = CallWaveLogLevelError;
    } else if (level == 2) {
        mapped = CallWaveLogLevelWarning;
    } else if (level == 3) {
        mapped = CallWaveLogLevelInfo;
    }
    if (mapped > CallWaveLog.level) {
        return;
    }

    while (length > 0 && (data[length - 1] == '\n' || data[length - 1] == '\r')) {
        length--;
    }
    if (length <= 0) {
        return;
    }
    NSString *message = [[NSString alloc] initWithBytes:data
                                                 length:(NSUInteger)length
                                               encoding:NSUTF8StringEncoding];
    if (message == nil) {
        return;
    }
    // The trace dumps whole SIP messages; digest responses must not reach the
    // log even at debug level unless redaction was deliberately disabled.
    message = [CallWaveLog scrubAuthorizationInMessage:message];
    [CallWaveLog logLevel:mapped category:CallWaveLogCategoryPJSIP format:@"%@", message];
}
