#import "PJSIPEngine.h"
#import "PJSIPThreadManager.h"
#import <pjsua.h>
#import <pthread.h>

// MARK: - Static State

static pj_bool_t s_pjInitialized = PJ_FALSE;
static pj_bool_t s_pjsuaCreated = PJ_FALSE;

// Weak reference to the singleton engine for C callbacks
static __weak PJSIPEngine *s_engineInstance = nil;

// MARK: - C Callback Functions

static void cb_on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    [PJSIPThreadManager ensureRegistered:@"IncomingCallCB"];

    NSString *callerUri = @"";
    NSString *callerName = @"";

    if (rdata && rdata->msg_info.from) {
        // Extract display name
        if (rdata->msg_info.from->name.slen > 0) {
            callerName = [[NSString alloc] initWithBytes:rdata->msg_info.from->name.ptr
                                                  length:rdata->msg_info.from->name.slen
                                                encoding:NSUTF8StringEncoding] ?: @"";
        }
        // Extract SIP URI
        if (rdata->msg_info.from->uri) {
            char uri_str[PJSIP_MAX_URL_SIZE];
            int len = pjsip_uri_print(PJSIP_URI_IN_FROMTO_HDR,
                                       rdata->msg_info.from->uri,
                                       uri_str, sizeof(uri_str));
            if (len > 0) {
                callerUri = [[NSString alloc] initWithBytes:uri_str
                                                     length:len
                                                   encoding:NSUTF8StringEncoding] ?: @"";
            }
        }
    }

    PJSIPEngine *engine = s_engineInstance;
    if (engine && engine.onIncomingCall) {
        // Capture values for the block
        int cid = (int)call_id;
        NSString *uri = [callerUri copy];
        NSString *name = [callerName copy];
        engine.onIncomingCall(cid, uri, name);
    }
}

static void cb_on_call_state(pjsua_call_id call_id, pjsip_event *e) {
    [PJSIPThreadManager ensureRegistered:@"CallStateCB"];
    PJ_UNUSED_ARG(e);

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info(call_id, &ci);
    if (status != PJ_SUCCESS) return;

    PJSIPEngine *engine = s_engineInstance;
    if (engine && engine.onCallState) {
        engine.onCallState((int)call_id, (int)ci.state, (int)ci.last_status);
    }
}

static void cb_on_call_media_state(pjsua_call_id call_id) {
    [PJSIPThreadManager ensureRegistered:@"MediaStateCB"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info(call_id, &ci);
    if (status != PJ_SUCCESS) return;

    PJSIPEngine *engine = s_engineInstance;
    if (engine && engine.onCallMediaState) {
        engine.onCallMediaState((int)call_id, (int)ci.media_status);
    }
}

static void cb_on_reg_state(pjsua_acc_id acc_id) {
    [PJSIPThreadManager ensureRegistered:@"RegStateCB"];

    pjsua_acc_info acc_info;
    pj_status_t status = pjsua_acc_get_info(acc_id, &acc_info);
    if (status != PJ_SUCCESS) return;

    NSString *statusText = @"";
    if (acc_info.status_text.slen > 0) {
        statusText = [[NSString alloc] initWithBytes:acc_info.status_text.ptr
                                              length:acc_info.status_text.slen
                                            encoding:NSUTF8StringEncoding] ?: @"";
    }

    PJSIPEngine *engine = s_engineInstance;
    if (engine && engine.onRegState) {
        engine.onRegState((int)acc_id, (int)acc_info.status, statusText);
    }
}

// MARK: - PJSIPEngine Implementation

@implementation PJSIPEngine {
    BOOL _initialized;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _initialized = NO;
        s_engineInstance = self;
    }
    return self;
}

- (void)dealloc {
    if (_initialized) {
        [self shutdown];
    }
    if (s_engineInstance == self) {
        s_engineInstance = nil;
    }
}

- (BOOL)isInitialized {
    return _initialized;
}

// MARK: - Lifecycle

- (int)initializeWithConfig:(NSDictionary *)config {
    if (_initialized) {
        return 0; // PJ_SUCCESS — already initialized
    }

    [PJSIPThreadManager ensureRegistered:@"EngineInit"];

    // 1. Initialize PJ library
    if (!s_pjInitialized) {
        pj_status_t status = pj_init();
        if (status != PJ_SUCCESS) {
            NSLog(@"[CallWaveSIP] pj_init failed: %d", status);
            return (int)status;
        }
        s_pjInitialized = PJ_TRUE;
    }

    // 2. Destroy existing instance if needed
    if (s_pjsuaCreated) {
        pjsua_destroy();
        s_pjsuaCreated = PJ_FALSE;
        usleep(100000); // 100ms pause for clean restart
    }

    // 3. Create PJSUA
    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] pjsua_create failed: %d", status);
        return (int)status;
    }
    s_pjsuaCreated = PJ_TRUE;

    // 4. Configure
    pjsua_config cfg;
    pjsua_logging_config log_cfg;
    pjsua_media_config media_cfg;
    pjsua_transport_config tp_cfg;

    pjsua_config_default(&cfg);
    pjsua_logging_config_default(&log_cfg);
    pjsua_media_config_default(&media_cfg);
    pjsua_transport_config_default(&tp_cfg);

    // Apply config values
    int maxCalls = [config[@"maxCalls"] intValue] ?: 30;
    int threadCount = [config[@"threadCount"] intValue] ?: 1;
    BOOL vadEnabled = [config[@"vadEnabled"] boolValue];
    BOOL sipTimerActive = [config[@"sipTimerActive"] boolValue];
    int logLevel = [config[@"logLevel"] intValue];
    int port = [config[@"port"] intValue]; // 0 = automatic

    cfg.max_calls = maxCalls;
    cfg.use_timer = sipTimerActive ? PJSUA_SIP_TIMER_OPTIONAL : PJSUA_SIP_TIMER_INACTIVE;

    media_cfg.has_ioqueue = PJ_TRUE;
    media_cfg.thread_cnt = threadCount;
    media_cfg.no_vad = vadEnabled ? PJ_FALSE : PJ_TRUE;

    // STUN/TURN/ICE
    NSString *stunServer = config[@"stunServer"];
    if (stunServer.length > 0) {
        cfg.stun_srv_cnt = 1;
        cfg.stun_srv[0] = pj_str((char *)[stunServer UTF8String]);
    }

    NSString *turnServer = config[@"turnServer"];
    // TURN is configured per-account, stored for later use

    BOOL iceEnabled = [config[@"iceEnabled"] boolValue];
    if (iceEnabled) {
        media_cfg.enable_ice = PJ_TRUE;
    }

    // User agent
    NSString *userAgent = config[@"userAgent"];
    if (userAgent.length > 0) {
        cfg.user_agent = pj_str((char *)[userAgent UTF8String]);
    }

    // Callbacks
    cfg.cb.on_incoming_call = &cb_on_incoming_call;
    cfg.cb.on_call_state = &cb_on_call_state;
    cfg.cb.on_call_media_state = &cb_on_call_media_state;
    cfg.cb.on_reg_state = &cb_on_reg_state;

    // Logging
    log_cfg.log_filename = pj_str(NULL);
    log_cfg.level = logLevel > 0 ? logLevel : 3;
    log_cfg.console_level = logLevel > 0 ? logLevel : 3;

    // Transport port
    if (port > 0) {
        tp_cfg.port = port;
    }

    // 5. Initialize PJSUA
    status = pjsua_init(&cfg, &log_cfg, &media_cfg);
    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] pjsua_init failed: %d", status);
        pjsua_destroy();
        s_pjsuaCreated = PJ_FALSE;
        return (int)status;
    }

    // 6. Create transports
    BOOL udpEnabled = config[@"udpEnabled"] ? [config[@"udpEnabled"] boolValue] : YES;
    BOOL tcpEnabled = config[@"tcpEnabled"] ? [config[@"tcpEnabled"] boolValue] : YES;
    BOOL tlsEnabled = [config[@"tlsEnabled"] boolValue];

    if (udpEnabled) {
        pjsua_transport_id tid;
        status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &tp_cfg, &tid);
        if (status != PJ_SUCCESS) {
            NSLog(@"[CallWaveSIP] UDP transport creation failed: %d", status);
            pjsua_destroy();
            s_pjsuaCreated = PJ_FALSE;
            return (int)status;
        }
    }

    if (tcpEnabled) {
        status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &tp_cfg, NULL);
        if (status != PJ_SUCCESS) {
            NSLog(@"[CallWaveSIP] TCP transport creation failed (non-fatal): %d", status);
            // Non-fatal — continue without TCP
        }
    }

    if (tlsEnabled) {
        pjsua_transport_config tls_cfg;
        pjsua_transport_config_default(&tls_cfg);
        if (port > 0) {
            tls_cfg.port = port + 1;
        }
        NSString *certPath = config[@"tlsCertificatePath"];
        if (certPath.length > 0) {
            tls_cfg.tls_setting.cert_file = pj_str((char *)[certPath UTF8String]);
        }
        status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &tls_cfg, NULL);
        if (status != PJ_SUCCESS) {
            NSLog(@"[CallWaveSIP] TLS transport creation failed (non-fatal): %d", status);
        }
    }

    // 7. Start PJSUA
    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] pjsua_start failed: %d", status);
        pjsua_destroy();
        s_pjsuaCreated = PJ_FALSE;
        return (int)status;
    }

    // 8. Disable sound device until explicitly activated
    pjsua_set_no_snd_dev();

    // 9. Apply codec priorities
    NSDictionary *codecPriorities = config[@"codecPriorities"];
    if (codecPriorities) {
        for (NSString *codec in codecPriorities) {
            int priority = [codecPriorities[codec] intValue];
            pj_str_t codecStr = pj_str((char *)[codec UTF8String]);
            pjsua_codec_set_priority(&codecStr, (pj_uint8_t)priority);
        }
    }

    _initialized = YES;
    NSLog(@"[CallWaveSIP] Engine initialized successfully");
    return 0; // PJ_SUCCESS
}

- (void)shutdown {
    if (!_initialized) return;

    [PJSIPThreadManager ensureRegistered:@"EngineShutdown"];

    if (s_pjsuaCreated) {
        pjsua_destroy();
        s_pjsuaCreated = PJ_FALSE;
    }

    [PJSIPThreadManager cleanup];
    _initialized = NO;
    NSLog(@"[CallWaveSIP] Engine shut down");
}

// MARK: - Account Management

- (int)createAccountWithDomain:(NSString *)domain
                      username:(NSString *)username
                      password:(NSString *)password
                          port:(int)port
                         realm:(NSString *)realm
                    regTimeout:(int)regTimeout
                     keepAlive:(int)keepAlive
                 retryInterval:(int)retryInterval
           retryRandomInterval:(int)retryRandomInterval
               contactRewrite:(BOOL)contactRewrite
         contactUseSourcePort:(BOOL)contactUseSourcePort
               autoRegister:(BOOL)autoRegister {
    if (!_initialized) return -1;

    [PJSIPThreadManager ensureRegistered:@"CreateAccount"];

    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);

    // Build SIP ID and registrar URI
    NSString *portSuffix = (port != 5060 && port > 0) ? [NSString stringWithFormat:@":%d", port] : @"";
    NSString *idString = [NSString stringWithFormat:@"sip:%@@%@%@", username, domain, portSuffix];
    NSString *regUri = [NSString stringWithFormat:@"sip:%@%@", domain, portSuffix];

    acc_cfg.id = pj_str((char *)[idString UTF8String]);
    acc_cfg.reg_uri = pj_str((char *)[regUri UTF8String]);

    // Credentials
    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].scheme = pj_str("digest");
    acc_cfg.cred_info[0].realm = pj_str((char *)[realm UTF8String]);
    acc_cfg.cred_info[0].username = pj_str((char *)[username UTF8String]);
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = pj_str((char *)[password UTF8String]);

    // Registration settings
    acc_cfg.reg_timeout = regTimeout;
    acc_cfg.ka_interval = keepAlive;
    acc_cfg.reg_retry_interval = retryInterval;
    acc_cfg.reg_retry_random_interval = retryRandomInterval;
    acc_cfg.contact_rewrite_method = contactRewrite ? 2 : 0;
    acc_cfg.allow_contact_rewrite = contactRewrite ? PJ_TRUE : PJ_FALSE;
    acc_cfg.contact_use_src_port = contactUseSourcePort ? PJ_TRUE : PJ_FALSE;

    pjsua_acc_id accId = PJSUA_INVALID_ID;
    pj_status_t status = pjsua_acc_add(&acc_cfg, autoRegister ? PJ_TRUE : PJ_FALSE, &accId);

    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] Account creation failed: %d", status);
        return -1;
    }

    if (!pjsua_acc_is_valid(accId)) {
        NSLog(@"[CallWaveSIP] Account invalid after creation: %d", accId);
        return -1;
    }

    NSLog(@"[CallWaveSIP] Account created with ID: %d", accId);
    return (int)accId;
}

- (int)removeAccount:(int)accountId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"RemoveAccount"];

    if (accountId < 0 || !pjsua_acc_is_valid((pjsua_acc_id)accountId)) {
        return -1;
    }

    pj_status_t status = pjsua_acc_del((pjsua_acc_id)accountId);
    return (int)status;
}

- (int)setRegistration:(BOOL)active forAccount:(int)accountId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"SetRegistration"];

    if (accountId < 0 || !pjsua_acc_is_valid((pjsua_acc_id)accountId)) {
        return -1;
    }

    pj_status_t status = pjsua_acc_set_registration((pjsua_acc_id)accountId,
                                                      active ? PJ_TRUE : PJ_FALSE);
    return (int)status;
}

- (int)getAccountStatus:(int)accountId {
    if (!_initialized || accountId < 0) return -1;
    [PJSIPThreadManager ensureRegistered:@"GetAccStatus"];

    pjsua_acc_info info;
    pj_status_t status = pjsua_acc_get_info((pjsua_acc_id)accountId, &info);
    if (status != PJ_SUCCESS) return -1;
    return (int)info.status;
}

- (int)getAccountExpiry:(int)accountId {
    if (!_initialized || accountId < 0) return -1;
    [PJSIPThreadManager ensureRegistered:@"GetAccExpiry"];

    pjsua_acc_info info;
    pj_status_t status = pjsua_acc_get_info((pjsua_acc_id)accountId, &info);
    if (status != PJ_SUCCESS) return -1;
    return (int)info.expires;
}

- (BOOL)isAccountValid:(int)accountId {
    if (!_initialized || accountId < 0) return NO;
    return pjsua_acc_is_valid((pjsua_acc_id)accountId) == PJ_TRUE;
}

// MARK: - Call Management

- (int)makeCall:(NSString *)uri account:(int)accountId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"MakeCall"];

    pj_str_t dest = pj_str((char *)[uri UTF8String]);
    pjsua_call_id callId = PJSUA_INVALID_ID;

    pj_status_t status = pjsua_call_make_call((pjsua_acc_id)accountId,
                                                &dest, NULL, NULL, NULL, &callId);
    if (status != PJ_SUCCESS) {
        NSLog(@"[CallWaveSIP] makeCall failed: %d", status);
        return -1;
    }
    return (int)callId;
}

- (int)answerCall:(int)callId code:(int)code {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"AnswerCall"];

    pj_status_t status = pjsua_call_answer((pjsua_call_id)callId, (unsigned)code, NULL, NULL);
    return (int)status;
}

- (int)answerCall:(int)callId code:(int)code audioCount:(int)audioCnt videoCount:(int)vidCnt {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"AnswerCall2"];

    pjsua_call_setting setting;
    pjsua_call_setting_default(&setting);
    setting.aud_cnt = audioCnt;
    setting.vid_cnt = vidCnt;

    pj_status_t status = pjsua_call_answer2((pjsua_call_id)callId, &setting, (unsigned)code, NULL, NULL);
    return (int)status;
}

- (int)hangupCall:(int)callId code:(int)code {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"HangupCall"];

    pj_status_t status = pjsua_call_hangup((pjsua_call_id)callId, (unsigned)code, NULL, NULL);
    return (int)status;
}

- (int)holdCall:(int)callId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"HoldCall"];

    pj_status_t status = pjsua_call_set_hold((pjsua_call_id)callId, NULL);
    return (int)status;
}

- (int)resumeCall:(int)callId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"ResumeCall"];

    pjsua_call_setting setting;
    pjsua_call_setting_default(&setting);
    setting.aud_cnt = 1;
    setting.vid_cnt = 0;

    pj_status_t status = pjsua_call_reinvite2((pjsua_call_id)callId, &setting, NULL);
    return (int)status;
}

- (int)sendDTMF:(int)callId digit:(NSString *)digit {
    if (!_initialized || digit.length == 0) return -1;
    [PJSIPThreadManager ensureRegistered:@"SendDTMF"];

    pj_str_t digits = pj_str((char *)[digit UTF8String]);
    pj_status_t status = pjsua_call_dial_dtmf((pjsua_call_id)callId, &digits);
    return (int)status;
}

- (int)transferCall:(int)callId to:(NSString *)destUri {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"TransferCall"];

    pj_str_t dest = pj_str((char *)[destUri UTF8String]);
    pj_status_t status = pjsua_call_xfer((pjsua_call_id)callId, &dest, NULL);
    return (int)status;
}

- (int)activeCallCount {
    if (!_initialized) return 0;
    return (int)pjsua_call_get_count();
}

- (BOOL)isCallActive:(int)callId {
    if (!_initialized) return NO;
    return pjsua_call_is_active((pjsua_call_id)callId) == PJ_TRUE;
}

- (int)getCallState:(int)callId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"GetCallState"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info((pjsua_call_id)callId, &ci);
    if (status != PJ_SUCCESS) return -1;
    return (int)ci.state;
}

- (int)getCallMediaStatus:(int)callId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"GetMediaStatus"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info((pjsua_call_id)callId, &ci);
    if (status != PJ_SUCCESS) return -1;
    return (int)ci.media_status;
}

- (int)getCallConfSlot:(int)callId {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"GetConfSlot"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info((pjsua_call_id)callId, &ci);
    if (status != PJ_SUCCESS) return -1;
    return (int)ci.conf_slot;
}

- (int)getMaxCallCount {
    if (!_initialized) return 0;
    return (int)pjsua_call_get_max_count();
}

- (nullable NSString *)getCallRemoteUri:(int)callId {
    if (!_initialized) return nil;
    [PJSIPThreadManager ensureRegistered:@"GetRemoteUri"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info((pjsua_call_id)callId, &ci);
    if (status != PJ_SUCCESS) return nil;

    if (ci.remote_info.slen > 0) {
        return [[NSString alloc] initWithBytes:ci.remote_info.ptr
                                        length:ci.remote_info.slen
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (nullable NSString *)getCallRemoteContact:(int)callId {
    if (!_initialized) return nil;
    [PJSIPThreadManager ensureRegistered:@"GetRemoteContact"];

    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info((pjsua_call_id)callId, &ci);
    if (status != PJ_SUCCESS) return nil;

    if (ci.remote_contact.slen > 0) {
        return [[NSString alloc] initWithBytes:ci.remote_contact.ptr
                                        length:ci.remote_contact.slen
                                      encoding:NSUTF8StringEncoding];
    }
    return nil;
}

// MARK: - Audio / Media

- (int)setSoundDeviceCapture:(int)capture playback:(int)playback {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"SetSndDev"];

    pj_status_t status = pjsua_set_snd_dev(capture, playback);
    return (int)status;
}

- (void)setNoSoundDevice {
    if (!_initialized) return;
    [PJSIPThreadManager ensureRegistered:@"NoSndDev"];
    pjsua_set_no_snd_dev();
}

- (int)connectConferencePort:(int)source to:(int)sink {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"ConfConnect"];

    pj_status_t status = pjsua_conf_connect((pjsua_conf_port_id)source,
                                              (pjsua_conf_port_id)sink);
    return (int)status;
}

- (int)disconnectConferencePort:(int)source from:(int)sink {
    if (!_initialized) return -1;
    [PJSIPThreadManager ensureRegistered:@"ConfDisconnect"];

    pj_status_t status = pjsua_conf_disconnect((pjsua_conf_port_id)source,
                                                 (pjsua_conf_port_id)sink);
    return (int)status;
}

- (int)adjustRxLevel:(int)slot level:(float)level {
    if (!_initialized) return -1;
    pj_status_t status = pjsua_conf_adjust_rx_level((pjsua_conf_port_id)slot, level);
    return (int)status;
}

- (int)adjustTxLevel:(int)slot level:(float)level {
    if (!_initialized) return -1;
    pj_status_t status = pjsua_conf_adjust_tx_level((pjsua_conf_port_id)slot, level);
    return (int)status;
}

// MARK: - Codec

- (int)setCodecPriority:(NSString *)codecId priority:(int)priority {
    if (!_initialized) return -1;
    pj_str_t codec = pj_str((char *)[codecId UTF8String]);
    pj_status_t status = pjsua_codec_set_priority(&codec, (pj_uint8_t)priority);
    return (int)status;
}

- (NSArray<NSString *> *)getAvailableCodecs {
    if (!_initialized) return @[];

    pjsua_codec_info codecs[64];
    unsigned count = 64;
    pj_status_t status = pjsua_enum_codecs(codecs, &count);
    if (status != PJ_SUCCESS) return @[];

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned i = 0; i < count; i++) {
        NSString *codecId = [[NSString alloc] initWithBytes:codecs[i].codec_id.ptr
                                                     length:codecs[i].codec_id.slen
                                                   encoding:NSUTF8StringEncoding];
        if (codecId) {
            [result addObject:codecId];
        }
    }
    return [result copy];
}

@end
