#ifndef PJSIPEngine_h
#define PJSIPEngine_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Low-level Objective-C wrapper around PJSIP C API.
/// This is the ONLY class that calls pjsua_* functions directly.
/// All other SDK modules interact with PJSIP exclusively through this engine.
@interface PJSIPEngine : NSObject

// MARK: - Lifecycle

/// Initialize the PJSIP library and SIP stack with the given configuration.
/// @param config Dictionary containing: maxCalls, threadCount, vadEnabled, sipTimerActive, logLevel,
///   udpEnabled, tcpEnabled, tlsEnabled, port, stunServer, turnServer, turnUsername, turnPassword,
///   iceEnabled, codecPriorities (dict of codec name -> priority)
/// @return 0 (PJ_SUCCESS) on success, error code otherwise.
- (int)initializeWithConfig:(NSDictionary *)config;

/// Shutdown the PJSIP library and release all resources.
- (void)shutdown;

/// Whether the PJSIP engine is currently initialized and running.
@property (nonatomic, readonly) BOOL isInitialized;

// MARK: - Account Management

/// Create and register a SIP account.
/// @return Account ID on success, -1 (PJSUA_INVALID_ID) on failure.
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
          autoRegister:(BOOL)autoRegister;

/// Remove a SIP account.
- (int)removeAccount:(int)accountId;

/// Enable or disable registration for an account.
- (int)setRegistration:(BOOL)active forAccount:(int)accountId;

/// Get account registration status code (200 = registered).
- (int)getAccountStatus:(int)accountId;

/// Get account registration expiry in seconds.
- (int)getAccountExpiry:(int)accountId;

/// Check if account ID is valid.
- (BOOL)isAccountValid:(int)accountId;

// MARK: - Call Management

/// Make an outgoing call. Returns call ID on success, -1 on failure.
- (int)makeCall:(NSString *)uri account:(int)accountId;

/// Answer an incoming call with a SIP status code.
- (int)answerCall:(int)callId code:(int)code;

/// Answer with extended settings (audio count, video count).
- (int)answerCall:(int)callId code:(int)code audioCount:(int)audioCnt videoCount:(int)vidCnt;

/// Hangup a call with optional status code. Use 0 for normal disconnect.
- (int)hangupCall:(int)callId code:(int)code;

/// Put a call on hold.
- (int)holdCall:(int)callId;

/// Resume a held call.
- (int)resumeCall:(int)callId;

/// Send a DTMF digit on a call.
- (int)sendDTMF:(int)callId digit:(NSString *)digit;

/// Transfer a call to another URI.
- (int)transferCall:(int)callId to:(NSString *)destUri;

/// Get the number of active calls.
- (int)activeCallCount;

/// Check if a specific call is active.
- (BOOL)isCallActive:(int)callId;

/// Get the call state for a given call ID.
/// Returns PJSIP inv_state value: 1=INCOMING, 2=CALLING, 3=EARLY, 4=CONNECTING, 5=CONFIRMED, 6=DISCONNECTED
- (int)getCallState:(int)callId;

/// Get the call media status for a given call ID.
- (int)getCallMediaStatus:(int)callId;

/// Get the conference slot for a call.
- (int)getCallConfSlot:(int)callId;

/// Get the maximum number of calls supported.
- (int)getMaxCallCount;

/// Get remote URI for a call.
- (nullable NSString *)getCallRemoteUri:(int)callId;

/// Get remote display name (contact) for a call.
- (nullable NSString *)getCallRemoteContact:(int)callId;

// MARK: - Audio / Media

/// Set sound device for capture and playback. Use -1/-2 for default devices.
- (int)setSoundDeviceCapture:(int)capture playback:(int)playback;

/// Disable sound device (silent mode).
- (void)setNoSoundDevice;

/// Connect two conference ports (e.g., call to speaker, mic to call).
- (int)connectConferencePort:(int)source to:(int)sink;

/// Disconnect two conference ports.
- (int)disconnectConferencePort:(int)source from:(int)sink;

/// Adjust the RX (receive) volume level for a conference port.
- (int)adjustRxLevel:(int)slot level:(float)level;

/// Adjust the TX (transmit) volume level for a conference port.
- (int)adjustTxLevel:(int)slot level:(float)level;

// MARK: - Codec

/// Set codec priority. Priority 0 = disabled, 255 = highest.
- (int)setCodecPriority:(NSString *)codecId priority:(int)priority;

/// Get list of available codecs.
- (NSArray<NSString *> *)getAvailableCodecs;

// MARK: - Callbacks

/// Called when an incoming call arrives.
/// Parameters: callId, callerUri, callerDisplayName
@property (nonatomic, copy, nullable) void(^onIncomingCall)(int callId, NSString *callerUri, NSString *callerDisplayName);

/// Called when a call state changes.
/// Parameters: callId, state (pjsip_inv_state), statusCode
@property (nonatomic, copy, nullable) void(^onCallState)(int callId, int state, int statusCode);

/// Called when call media state changes.
/// Parameters: callId, mediaStatus
@property (nonatomic, copy, nullable) void(^onCallMediaState)(int callId, int mediaStatus);

/// Called when account registration state changes.
/// Parameters: accountId, statusCode, statusText
@property (nonatomic, copy, nullable) void(^onRegState)(int accountId, int statusCode, NSString *statusText);

/// Called when transport state changes.
/// Parameters: transportName, state, statusCode
@property (nonatomic, copy, nullable) void(^onTransportState)(NSString *transportName, int state, int statusCode);

@end

NS_ASSUME_NONNULL_END

#endif /* PJSIPEngine_h */
