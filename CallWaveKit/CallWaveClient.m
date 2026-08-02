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

static NSString *const CallWaveDefaultCallerName = @"Домофон";
static const NSTimeInterval CallWaveAnswerPollInterval = 0.25;
static const NSTimeInterval CallWaveAudioFallbackDelay = 1.5;
static const NSUInteger CallWaveDTMFDurationMilliseconds = 160;

static pj_bool_t gPJInitialized = PJ_FALSE;
static pj_bool_t gPJSUACreated = PJ_FALSE;
static pj_bool_t gPJSUAStarted = PJ_FALSE;
static pjsua_acc_id gAccountId = PJSUA_INVALID_ID;
static NSUInteger gCreatedTransports = 0;
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

/// `pjsua_acc_info.expires` is `PJSIP_EXPIRES_NOT_SPECIFIED` (0xFFFFFFFF), not
/// zero, once the registration session is gone — which is exactly the state a
/// successful un-REGISTER leaves behind, with `status` still 200.
static BOOL registrationIsActive(const pjsua_acc_info *info) {
    return info->status == PJSIP_SC_OK &&
           info->expires > 0 &&
           info->expires != PJSIP_EXPIRES_NOT_SPECIFIED;
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

static NSString *transportURIParameterForTransport(CallWaveTransport transport) {
    switch (transport) {
        case CallWaveTransportTCP:
            return @";transport=tcp";
        case CallWaveTransportTLS:
            return @";transport=tls";
        case CallWaveTransportUDP:
            break;
    }
    return @"";
}

static NSUInteger defaultPortForTransport(CallWaveTransport transport) {
    return transport == CallWaveTransportTLS ? 5061 : 5060;
}

@implementation CallWaveConfiguration

- (instancetype)initWithHost:(NSString *)host
                        port:(NSUInteger)port
                   transport:(CallWaveTransport)transport
                    username:(NSString *)username
                    password:(NSString *)password
      includesCallsInRecents:(BOOL)includesCallsInRecents {
    self = [super init];
    if (self) {
        NSCharacterSet *trimmed = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        _host = [[host stringByTrimmingCharactersInSet:trimmed] copy] ?: @"";
        _port = port;
        _transport = transport;
        _username = [[username stringByTrimmingCharactersInSet:trimmed] copy] ?: @"";
        _password = [password copy] ?: @"";
        _includesCallsInRecents = includesCallsInRecents;
    }
    return self;
}

- (instancetype)initWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
        includesCallsInRecents:(BOOL)includesCallsInRecents {
    NSString *value = [domain stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *host = value;
    NSUInteger port = 0;

    // Only a trailing `:port` is split. IPv6 literals keep their colons and are
    // expected to arrive bracketed, as SIP URIs require.
    if (![value hasPrefix:@"["]) {
        NSRange colon = [value rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location != NSNotFound) {
            NSString *tail = [value substringFromIndex:NSMaxRange(colon)];
            NSScanner *scanner = [NSScanner scannerWithString:tail];
            int parsed = 0;
            if ([scanner scanInt:&parsed] && scanner.isAtEnd && parsed > 0) {
                host = [value substringToIndex:colon.location];
                port = (NSUInteger)parsed;
            }
        }
    }

    return [self initWithHost:host
                         port:port
                    transport:CallWaveTransportUDP
                     username:username
                     password:password
       includesCallsInRecents:includesCallsInRecents];
}

- (NSString *)domain {
    return self.port > 0
        ? [NSString stringWithFormat:@"%@:%lu", self.host, (unsigned long)self.port]
        : self.host;
}

- (NSString *)identityURI {
    return [NSString stringWithFormat:@"sip:%@@%@", self.username, self.host];
}

- (NSString *)registrarURI {
    return [NSString stringWithFormat:@"sip:%@:%lu%@",
            self.host,
            (unsigned long)(self.port > 0 ? self.port : defaultPortForTransport(self.transport)),
            transportURIParameterForTransport(self.transport)];
}

- (BOOL)isEqualToConfiguration:(CallWaveConfiguration *)other {
    if (other == nil) {
        return NO;
    }
    if (other == self) {
        return YES;
    }
    return [self.host isEqualToString:other.host] &&
           self.port == other.port &&
           self.transport == other.transport &&
           [self.username isEqualToString:other.username] &&
           [self.password isEqualToString:other.password];
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:CallWaveConfiguration.class]) {
        return NO;
    }
    CallWaveConfiguration *other = object;
    return [self isEqualToConfiguration:other] &&
           self.includesCallsInRecents == other.includesCallsInRecents;
}

- (NSUInteger)hash {
    return self.host.hash ^ self.username.hash ^ self.port ^ (NSUInteger)self.transport;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[CallWaveConfiguration allocWithZone:zone]
              initWithHost:self.host
                      port:self.port
                 transport:self.transport
                  username:self.username
                  password:self.password
    includesCallsInRecents:self.includesCallsInRecents];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@ via %@>",
            NSStringFromClass(self.class), self.identityURI, self.registrarURI];
}

@end

@interface CallWaveClient () <CXProviderDelegate, PKPushRegistryDelegate>
@property (nonatomic, strong, nullable, readwrite) CallWaveConfiguration *configuration;
@property (nonatomic, assign, readwrite) CallWaveIntegrationOptions integrationOptions;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign, readwrite) CallWaveRegistrationState registrationState;
@property (nonatomic, assign, readwrite) CallWaveCallState callState;
@property (nonatomic, copy, nullable, readwrite) NSString *currentCaller;
@property (nonatomic, strong, nullable, readwrite) CXProvider *provider;
@property (nonatomic, strong, readwrite) CXCallController *callController;
@property (nonatomic, strong, readwrite) NSMutableDictionary<NSString *, NSDictionary *> *activeCalls;
@property (nonatomic, strong, readwrite) NSMutableSet<NSString *> *reportedCallUUIDs;
@property (nonatomic, strong, nullable, readwrite) NSUUID *currentCallUUID;
@property (nonatomic, assign, readwrite) pjsua_call_id currentCallIdentifier;
@property (nonatomic, strong, nullable) PKPushRegistry *pushRegistry;
@property (nonatomic, assign) BOOL audioSessionActive;
@property (nonatomic, assign, readwrite) BOOL microphoneMuted;
@property (nonatomic, strong) dispatch_queue_t sipQueue;

// Declared for the PJSUA C callbacks at the bottom of this file, which sit
// outside the @implementation and therefore need a visible interface.
- (BOOL)managesCallKit;
- (void)setupCallKit;
- (void)complete:(nullable CallWaveCompletion)completion error:(nullable NSError *)error;
- (NSString *)displayNameForCaller:(NSString *)caller;
- (void)publishCallState:(CallWaveCallState)state uuid:(nullable NSUUID *)uuid;
- (pjsua_call_id)callIdForUUID:(NSUUID *)uuid;
- (void)associateSIPCall:(pjsua_call_id)callId
                withUUID:(NSUUID *)uuid
                  caller:(NSString *)caller;
- (void)clearCallWithUUID:(nullable NSUUID *)uuid callId:(pjsua_call_id)callId;
- (void)reportCallEndedWithUUID:(nullable NSUUID *)uuid reason:(CXCallEndedReason)reason;
- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(nullable NSString *)caller
                         forCallId:(pjsua_call_id)callId;
- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(nullable NSString *)caller
                         forCallId:(pjsua_call_id)callId
                        completion:(nullable CallWaveCompletion)completion;
- (void)attemptAcceptForUUID:(NSUUID *)uuid
                    deadline:(NSDate *)deadline
                  completion:(nullable CallWaveCompletion)completion;
- (void)connectMediaForCall:(pjsua_call_id)callId;
- (BOOL)applyMicrophoneMuted:(BOOL)muted;
- (BOOL)answerSIPCall:(pjsua_call_id)callId;
- (BOOL)declineSIPCall:(pjsua_call_id)callId;
- (BOOL)hangupSIPCall:(pjsua_call_id)callId;
- (BOOL)stopCall;
- (void)wakeRegistration;
- (void)prepareAudioSession;
- (BOOL)prepareAudioSessionWithError:(NSError * _Nullable * _Nullable)error;
- (void)openSoundDevice;
- (void)scheduleAudioSessionFallback;
- (BOOL)claimRuntimeWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)validateConfiguration:(CallWaveConfiguration *)configuration
                        error:(NSError * _Nullable * _Nullable)error;
- (BOOL)validateAccountWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)setRegistrationEnabled:(BOOL)enabled
                       context:(NSString *)context
                         error:(NSError * _Nullable * _Nullable)error;
- (pj_status_t)startEngineLocked;
- (pj_status_t)applyConfigurationLocked:(CallWaveConfiguration *)configuration;
- (pj_status_t)ensureTransportLocked:(CallWaveTransport)transport;
- (NSString *)normalizedDTMFDigits:(NSString *)digits;
- (pj_status_t)sendDTMFDigits:(NSString *)digits
                       callId:(pjsua_call_id)callId
                       method:(pjsua_dtmf_method)method;
@end

@implementation CallWaveClient

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration {
    return [self initWithConfiguration:configuration
                              options:CallWaveIntegrationOptionManagesEverything
                             provider:nil];
}

- (instancetype)initWithConfiguration:(CallWaveConfiguration *)configuration
                              options:(CallWaveIntegrationOptions)options
                             provider:(CXProvider *)provider {
    self = [super init];
    if (self) {
        _configuration = [configuration copy];
        _integrationOptions = options;
        _activeCalls = [NSMutableDictionary dictionary];
        _reportedCallUUIDs = [NSMutableSet set];
        _currentCallIdentifier = PJSUA_INVALID_ID;
        _registrationState = CallWaveRegistrationStateStopped;
        _callState = CallWaveCallStateIdle;
        _answerTimeout = 10.0;
        _dtmfMethod = CallWaveDTMFMethodAuto;
        _sipQueue = dispatch_queue_create("com.callwave.pjsip", DISPATCH_QUEUE_SERIAL);
        _callController = [[CXCallController alloc] init];
        if (options & CallWaveIntegrationOptionManagesCallKit) {
            [self setupCallKit];
        } else {
            // Host-owned CallKit: the library never creates a second provider
            // and never becomes a provider delegate. It only reports call
            // termination through the injected provider, if there is one.
            _provider = provider;
        }
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

static NSError *CallWaveMakeSIPError(pj_status_t status, NSString *context) {
    char reason[PJ_ERR_MSG_SIZE] = {0};
    pj_strerror(status, reason, sizeof(reason));
    return CallWaveMakeError(CallWaveErrorSIPFailure,
                             [NSString stringWithFormat:@"%@ failed: %s (%d).",
                              context, reason, status]);
}

- (BOOL)managesCallKit {
    return (self.integrationOptions & CallWaveIntegrationOptionManagesCallKit) != 0;
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
    if (![self claimRuntimeWithError:error]) {
        return NO;
    }

    __block pj_status_t status = PJ_SUCCESS;
    dispatch_sync(self.sipQueue, ^{
        status = [self startEngineLocked];
    });
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
    dispatch_sync(self.sipQueue, ^{
        status = [self applyConfigurationLocked:copy];
    });

    if (status != PJ_SUCCESS) {
        self.registrationState = CallWaveRegistrationStateFailed;
        if (error != NULL) {
            *error = CallWaveMakeSIPError(status, @"SIP account setup");
        }
        return NO;
    }
    self.configuration = copy;
    return YES;
}

/// Creates the PJSUA runtime once. Must run on `sipQueue`.
- (pj_status_t)startEngineLocked {
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
        NSLog(@"SIP: optional TCP transport unavailable (%d)", tcpStatus);
    }

    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        return status;
    }
    gPJSUAStarted = PJ_TRUE;
    pjsua_set_no_snd_dev();
    return PJ_SUCCESS;
}

/// Must run on `sipQueue`.
- (pj_status_t)ensureTransportLocked:(CallWaveTransport)transport {
    NSUInteger bit = 1u << (NSUInteger)transport;
    if (gCreatedTransports & bit) {
        return PJ_SUCCESS;
    }

    pjsua_transport_config config;
    pjsua_transport_config_default(&config);
    config.port = 0;

    pj_status_t status = pjsua_transport_create(pjTransportForCallWaveTransport(transport),
                                               &config,
                                               NULL);
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

    NSString *identity = configuration.identityURI;
    NSString *registrar = configuration.registrarURI;
    NSString *username = configuration.username;
    NSString *password = configuration.password;

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

    pj_status_t status = pjsua_acc_add(&account, PJ_TRUE, &gAccountId);
    if (status == PJ_SUCCESS) {
        NSLog(@"SIP: registration started for %@ via %@", identity, registrar);
    }
    return status;
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
            registered = registrationIsActive(&info);
        }
    });
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
    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveRegistration");
        status = pjsua_acc_set_registration(gAccountId, enabled ? PJ_TRUE : PJ_FALSE);
    });
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
    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveUnregisterCheck");
        pjsua_acc_info info;
        if (pjsua_acc_get_info(gAccountId, &info) == PJ_SUCCESS) {
            hasSession = info.expires != PJSIP_EXPIRES_NOT_SPECIFIED && info.expires > 0;
        }
    });
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

    dispatch_sync(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveLogout");
        pjsua_acc_set_registration(gAccountId, PJ_FALSE);
        pjsua_acc_del(gAccountId);
        gAccountId = PJSUA_INVALID_ID;
    });
    self.configuration = nil;
    self.registrationState = CallWaveRegistrationStateStopped;
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
        gCreatedTransports = 0;
    });

    self.running = NO;
    self.registrationState = CallWaveRegistrationStateStopped;
    self.callState = CallWaveCallStateIdle;
    self.currentCallUUID = nil;
    self.currentCallIdentifier = PJSUA_INVALID_ID;
    self.currentCaller = nil;
    self.microphoneMuted = NO;
    [self.activeCalls removeAllObjects];
    [self.reportedCallUUIDs removeAllObjects];
    @synchronized (CallWaveClient.class) {
        if (gActiveClient == self) {
            gActiveClient = nil;
        }
    }
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

- (BOOL)declineSIPCall:(pjsua_call_id)callId {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveDecline");
    return pjsua_call_answer(callId, PJSIP_SC_DECLINE, NULL, NULL) == PJ_SUCCESS;
}

- (BOOL)hangupSIPCall:(pjsua_call_id)callId {
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        return NO;
    }
    ensurePJThreadRegistered("CallWaveHangup");
    return pjsua_call_hangup(callId, 0, NULL, NULL) == PJ_SUCCESS;
}

- (BOOL)declineCall {
    return [self declineSIPCall:self.currentCallIdentifier];
}

- (BOOL)stopCall {
    return [self hangupSIPCall:self.currentCallIdentifier];
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

#pragma mark - Direct call control

- (void)acceptCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    [self acceptCallWithUUID:uuid timeout:self.answerTimeout completion:completion];
}

- (void)acceptCallWithUUID:(NSUUID *)uuid
                   timeout:(NSTimeInterval)timeout
                completion:(CallWaveCompletion)completion {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0)];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *target = uuid ?: self.currentCallUUID;
        if (target == nil) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to answer.")];
            return;
        }
        // The audio session category must be in place before the answer so the
        // media path is ready when CallKit activates the session.
        [self configureAudioSessionWithError:NULL];
        [self attemptAcceptForUUID:target deadline:deadline completion:completion];
    });
}

/// Runs on the main queue. The INVITE frequently arrives after CallKit has
/// answered, so the call is polled instead of blocking a CallKit action.
- (void)attemptAcceptForUUID:(NSUUID *)uuid
                    deadline:(NSDate *)deadline
                  completion:(CallWaveCompletion)completion {
    pjsua_call_id callId = [self callIdForUUID:uuid];
    if (callId == PJSUA_INVALID_ID && [uuid isEqual:self.currentCallUUID]) {
        callId = self.currentCallIdentifier;
    }

    if (callId == PJSUA_INVALID_ID) {
        if (deadline.timeIntervalSinceNow <= 0) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorTimedOut,
                                             @"The SIP INVITE did not arrive in time.")];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(CallWaveAnswerPollInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self attemptAcceptForUUID:uuid deadline:deadline completion:completion];
        });
        return;
    }

    dispatch_async(self.sipQueue, ^{
        BOOL answered = [self answerSIPCall:callId];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!answered) {
                [self complete:completion
                         error:CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                 @"The SIP call could not be answered.")];
                return;
            }
            [self publishCallState:CallWaveCallStateConnecting uuid:uuid];
            [self scheduleAudioSessionFallback];
            [self complete:completion error:nil];
        });
    });
}

- (void)endCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *target = uuid ?: self.currentCallUUID;
        pjsua_call_id callId = target != nil ? [self callIdForUUID:target] : PJSUA_INVALID_ID;
        if (callId == PJSUA_INVALID_ID) {
            callId = self.currentCallIdentifier;
        }
        if (callId == PJSUA_INVALID_ID) {
            [self clearCallWithUUID:target callId:PJSUA_INVALID_ID];
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to end.")];
            return;
        }

        dispatch_async(self.sipQueue, ^{
            BOOL ended = [self hangupSIPCall:callId];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self clearCallWithUUID:target callId:callId];
                [self publishCallState:CallWaveCallStateEnded uuid:target];
                [self complete:completion
                         error:ended ? nil
                                     : CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                         @"The SIP call could not be ended.")];
            });
        });
    });
}

- (void)declineCallWithUUID:(NSUUID *)uuid completion:(CallWaveCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *target = uuid ?: self.currentCallUUID;
        pjsua_call_id callId = target != nil ? [self callIdForUUID:target] : PJSUA_INVALID_ID;
        if (callId == PJSUA_INVALID_ID) {
            callId = self.currentCallIdentifier;
        }
        if (callId == PJSUA_INVALID_ID) {
            [self clearCallWithUUID:target callId:PJSUA_INVALID_ID];
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                             @"There is no call to decline.")];
            return;
        }

        dispatch_async(self.sipQueue, ^{
            BOOL declined = [self declineSIPCall:callId];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self clearCallWithUUID:target callId:callId];
                [self publishCallState:CallWaveCallStateEnded uuid:target];
                [self complete:completion
                         error:declined ? nil
                                        : CallWaveMakeError(CallWaveErrorCallActionFailed,
                                                            @"The SIP call could not be declined.")];
            });
        });
    });
}

- (BOOL)setMicrophoneMuted:(BOOL)muted error:(NSError **)error {
    if (self.currentCallIdentifier == PJSUA_INVALID_ID) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorNoActiveCall,
                                       @"There is no call to mute.");
        }
        return NO;
    }
    if (![self applyMicrophoneMuted:muted]) {
        if (error != NULL) {
            *error = CallWaveMakeError(CallWaveErrorCallActionFailed,
                                       @"The microphone state could not be changed.");
        }
        return NO;
    }
    return YES;
}

#pragma mark - DTMF

- (NSString *)normalizedDTMFDigits:(NSString *)digits {
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

- (void)sendDTMF:(NSString *)digits completion:(CallWaveCompletion)completion {
    [self sendDTMF:digits method:self.dtmfMethod completion:completion];
}

- (void)sendDTMF:(NSString *)digits
          method:(CallWaveDTMFMethod)method
      completion:(CallWaveCompletion)completion {
    NSString *normalized = [self normalizedDTMFDigits:digits ?: @""];
    if (normalized.length == 0) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorInvalidArgument,
                                         @"DTMF digits must be 0-9, A-D, * or #.")];
        return;
    }

    pjsua_call_id callId = self.currentCallIdentifier;
    if (!gPJSUAStarted || callId == PJSUA_INVALID_ID) {
        [self complete:completion
                 error:CallWaveMakeError(CallWaveErrorNoActiveCall,
                                         @"There is no call to send DTMF on.")];
        return;
    }

    dispatch_async(self.sipQueue, ^{
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
                NSLog(@"SIP: RFC 2833 DTMF failed (%d), retrying with SIP INFO", status);
            }
            context = @"SIP INFO DTMF";
            status = [self sendDTMFDigits:normalized
                                  callId:callId
                                  method:PJSUA_DTMF_METHOD_SIP_INFO];
        }

        [self complete:completion
                 error:status == PJ_SUCCESS ? nil : CallWaveMakeSIPError(status, context)];
    });
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

- (BOOL)prepareAudioSessionWithError:(NSError **)error {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *categoryError = nil;
    AVAudioSessionCategoryOptions options =
        AVAudioSessionCategoryOptionAllowBluetoothHFP |
        AVAudioSessionCategoryOptionDefaultToSpeaker;
    if ([session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeVoiceChat
                     options:options
                       error:&categoryError]) {
        return YES;
    }
    NSLog(@"Audio: category configuration failed: %@", categoryError);
    if (error != NULL) {
        *error = categoryError ?: CallWaveMakeError(CallWaveErrorAudioSessionFailure,
                                                    @"The audio category could not be set.");
    }
    return NO;
}

- (void)prepareAudioSession {
    [self prepareAudioSessionWithError:NULL];
}

- (BOOL)configureAudioSessionWithError:(NSError **)error {
    return [self prepareAudioSessionWithError:error];
}

- (BOOL)activateAudioSessionWithError:(NSError **)error {
    [self prepareAudioSessionWithError:error];
    NSError *activationError = nil;
    if (![AVAudioSession.sharedInstance setActive:YES
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                            error:&activationError]) {
        NSLog(@"Audio: activation failed: %@", activationError);
        if (error != NULL) {
            *error = activationError ?: CallWaveMakeError(CallWaveErrorAudioSessionFailure,
                                                          @"The audio session could not be activated.");
        }
        return NO;
    }

    [self openSoundDevice];
    return YES;
}

- (BOOL)activateSoundDevice {
    return [self activateAudioSessionWithError:NULL];
}

/// Opens the PJSIP sound device and re-links the conference bridge. Safe to
/// call more than once.
- (void)openSoundDevice {
    self.audioSessionActive = YES;
    dispatch_async(self.sipQueue, ^{
        if (!gPJSUAStarted) {
            return;
        }
        ensurePJThreadRegistered("CallWaveAudio");
        pj_status_t status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                                               PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
        if (status != PJ_SUCCESS) {
            NSLog(@"Audio: PJSIP sound device failed (%d)", status);
            return;
        }
        [self connectMediaForCall:self.currentCallIdentifier];
    });
}

/// CallKit does not always deliver `-didActivateAudioSession:` — most often on
/// a cold start answered from the lock screen. Activating the session manually
/// a moment later is what keeps two-way audio working.
- (void)scheduleAudioSessionFallback {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(CallWaveAudioFallbackDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.audioSessionActive || self.currentCallIdentifier == PJSUA_INVALID_ID) {
            return;
        }
        NSLog(@"Audio: CallKit did not activate the session, activating manually");
        [self activateAudioSessionWithError:NULL];
    });
}

- (void)audioSessionDidActivate:(AVAudioSession *)audioSession {
    [self openSoundDevice];
}

- (void)audioSessionDidDeactivate:(AVAudioSession *)audioSession {
    self.audioSessionActive = NO;
    dispatch_async(self.sipQueue, ^{
        ensurePJThreadRegistered("CallWaveCallKitAudioOff");
        if (gPJSUAStarted) {
            pjsua_set_no_snd_dev();
        }
    });
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
        return CallWaveDefaultCallerName;
    }
    ensurePJThreadRegistered("CallWaveCallerInfo");
    pjsua_call_info info;
    if (pjsua_call_get_info(callId, &info) != PJ_SUCCESS) {
        return CallWaveDefaultCallerName;
    }
    return [self displayNameForCaller:stringFromPJString(info.remote_info)];
}

- (NSString *)displayNameForCaller:(NSString *)caller {
    if (caller.length == 0) {
        return CallWaveDefaultCallerName;
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
    if (self.provider != nil || !self.managesCallKit) {
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
}

- (void)prepareIncomingCallWithUUID:(NSUUID *)uuid caller:(NSString *)caller {
    if (uuid == nil) {
        return;
    }
    NSString *resolved = caller.length > 0 ? caller : CallWaveDefaultCallerName;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *key = uuid.UUIDString;
        pjsua_call_id known = [self callIdForUUID:uuid];
        if (known == PJSUA_INVALID_ID && self.currentCallIdentifier != PJSUA_INVALID_ID) {
            // The INVITE beat the host's report.
            [self associateSIPCall:self.currentCallIdentifier withUUID:uuid caller:resolved];
        } else {
            NSMutableDictionary *call = [self.activeCalls[key] mutableCopy]
                ?: [NSMutableDictionary dictionary];
            call[@"call_id"] = @(known);
            call[@"caller"] = resolved;
            call[@"created_at"] = @([NSDate date].timeIntervalSince1970);
            self.activeCalls[key] = call;
            self.currentCallUUID = uuid;
            self.currentCaller = [self displayNameForCaller:resolved];
        }
        [self.reportedCallUUIDs addObject:key];
        [self publishCallState:CallWaveCallStateIncoming uuid:uuid];
        [self configureAudioSessionWithError:NULL];
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
                          forCallId:PJSUA_INVALID_ID
                         completion:completion];
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(NSString *)caller
                         forCallId:(pjsua_call_id)callId {
    [self reportIncomingCallWithUUID:uuid caller:caller forCallId:callId completion:nil];
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid
                            caller:(NSString *)caller
                         forCallId:(pjsua_call_id)callId
                        completion:(CallWaveCompletion)completion {
    NSString *resolved = caller.length > 0 ? caller : CallWaveDefaultCallerName;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupCallKit];
        if (self.provider == nil) {
            [self complete:completion
                     error:CallWaveMakeError(CallWaveErrorCallActionFailed,
                                             @"No CXProvider to report the call on.")];
            return;
        }

        NSString *key = uuid.UUIDString;
        if ([self.reportedCallUUIDs containsObject:key]) {
            if (callId != PJSUA_INVALID_ID) {
                [self associateSIPCall:callId withUUID:uuid caller:resolved];
            }
            [self complete:completion error:nil];
            return;
        }

        CXCallUpdate *update = [[CXCallUpdate alloc] init];
        update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric
                                                       value:resolved];
        update.localizedCallerName = [self displayNameForCaller:resolved];
        update.hasVideo = NO;
        update.supportsHolding = NO;
        update.supportsGrouping = NO;
        update.supportsUngrouping = NO;
        // Door openers are DTMF, so the call must advertise DTMF support.
        update.supportsDTMF = YES;

        self.activeCalls[key] = @{
            @"call_id": @(callId),
            @"caller": resolved,
            @"created_at": @([NSDate date].timeIntervalSince1970)
        };
        self.currentCallUUID = uuid;
        self.currentCaller = update.localizedCallerName;
        if (callId != PJSUA_INVALID_ID) {
            self.currentCallIdentifier = callId;
        }
        [self publishCallState:CallWaveCallStateIncoming uuid:uuid];
        [self.reportedCallUUIDs addObject:key];
        [self configureAudioSessionWithError:NULL];

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
                         didReceiveCallFrom:self.currentCaller ?: CallWaveDefaultCallerName
                                       uuid:uuid];
                }
            }
            // Only now may a PushKit completion handler run.
            if (completion != nil) {
                completion(error);
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
    call[@"caller"] = caller.length > 0 ? caller : CallWaveDefaultCallerName;
    self.activeCalls[key] = call;
    self.currentCallUUID = uuid;
    self.currentCaller = [self displayNameForCaller:caller];
    self.currentCallIdentifier = callId;
}

- (void)endCallWithUUID:(NSUUID *)uuid {
    [self endCallWithUUID:uuid completion:nil];
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
        self.currentCallUUID = nil;
        self.microphoneMuted = NO;
    }
}

/// Reports termination through whichever provider exists and always tells the
/// delegate, so a host that kept its provider private can report it itself.
- (void)reportCallEndedWithUUID:(NSUUID *)uuid reason:(CXCallEndedReason)reason {
    if (uuid == nil) {
        return;
    }
    [self.provider reportCallWithUUID:uuid endedAtDate:[NSDate date] reason:reason];
    id<CallWaveClientDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(callWaveClient:didEndCallWithUUID:reason:)]) {
        [delegate callWaveClient:self didEndCallWithUUID:uuid reason:reason];
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
    self.microphoneMuted = NO;
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
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
        NSLog(@"CallKit: answering failed: %@", error);
        [self reportCallEndedWithUUID:action.callUUID reason:CXCallEndedReasonFailed];
        [self clearCallWithUUID:action.callUUID callId:PJSUA_INVALID_ID];
        [self publishCallState:CallWaveCallStateEnded uuid:action.callUUID];
    }];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    pjsua_call_id callId = [self callIdForUUID:action.callUUID];
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

- (void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action {
    [self sendDTMF:action.digits completion:^(NSError *error) {
        error == nil ? [action fulfill] : [action fail];
    }];
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    [self audioSessionDidActivate:audioSession];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    [self audioSessionDidDeactivate:audioSession];
}

#pragma mark - PushKit

- (void)registerForVoIPPushes {
    if ((self.integrationOptions & CallWaveIntegrationOptionManagesVoIPPushRegistry) == 0) {
        // The host owns the only PKPushRegistry in the process.
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
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
                NSLog(@"CallWave: start after VoIP push failed: %@", error);
            }
            return;
        }
        dispatch_sync(self.sipQueue, ^{
            ensurePJThreadRegistered("CallWavePushRegister");
            pjsua_acc_set_registration(gAccountId, PJ_TRUE);
        });
    });
}

- (void)handleVoIPPushPayload:(NSDictionary *)payload {
    [self handleVoIPPushPayload:payload completion:nil];
}

- (void)handleVoIPPushPayload:(NSDictionary *)payload
                   completion:(void (^)(void))completion {
    NSDictionary *data = [payload[@"data"] isKindOfClass:NSDictionary.class] ? payload[@"data"] : nil;
    NSString *uuidString = data[@"uuid"] ?: payload[@"uuid"];
    NSUUID *uuid = uuidString.length > 0 ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    if (uuid == nil) {
        uuid = [NSUUID UUID];
    }

    NSString *caller = data[@"callerID"] ?: data[@"caller"] ?: payload[@"caller_id"]
        ?: CallWaveDefaultCallerName;

    // PushKit terminates the process with 0xBAADCA11 if its completion handler
    // runs before CallKit has accepted the call, so it is invoked from inside
    // the report completion and exactly once.
    __block BOOL completionCalled = NO;
    void (^acknowledge)(NSError *) = ^(NSError *error) {
        if (completionCalled || completion == nil) {
            return;
        }
        completionCalled = YES;
        completion();
    };

    [self reportIncomingCallWithUUID:uuid caller:caller completion:acknowledge];
    [self wakeRegistration];
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
    if (![type isEqualToString:PKPushTypeVoIP]) {
        completion();
        return;
    }
    [self handleVoIPPushPayload:payload.dictionaryPayload completion:completion];
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
    pjsua_call_answer(callId, PJSIP_SC_RINGING, NULL, NULL);

    pjsua_call_info info;
    NSString *caller = CallWaveDefaultCallerName;
    if (pjsua_call_get_info(callId, &info) == PJ_SUCCESS) {
        caller = [integration displayNameForCaller:stringFromPJString(info.remote_info)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUUID *uuid = integration.currentCallUUID;
        if (uuid != nil && [integration callIdForUUID:uuid] == PJSUA_INVALID_ID) {
            [integration associateSIPCall:callId withUUID:uuid caller:caller];
        } else if (uuid == nil) {
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
        [integration reportCallEndedWithUUID:uuid reason:CXCallEndedReasonRemoteEnded];
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
        if (registrationIsActive(&info)) {
            client.registrationState = CallWaveRegistrationStateRegistered;
        } else if (info.status >= 300) {
            client.registrationState = CallWaveRegistrationStateFailed;
        } else if (info.status == PJSIP_SC_OK) {
            // 200 with no registration session left: the un-REGISTER succeeded.
            client.registrationState = CallWaveRegistrationStateStopped;
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
