//
//  PJSIPIntegration.h
//  SIOSP
//
//  Created by Flavien SICARD on 1/19/19.
//  Copyright © 2019 sicardf. All rights reserved.
//

#ifndef PJSIPIntegration_h
#define PJSIPIntegration_h

#import <Foundation/Foundation.h>
#import <pjsua.h>
#import <CallKit/CallKit.h>
#import <PushKit/PushKit.h>

@import AVFoundation;

@interface PJSIPIntegration : NSObject <CXProviderDelegate, PKPushRegistryDelegate>

+ (instancetype _Nonnull)sharedInstance;

// Свойства для работы с CallKit
@property (nonatomic, strong) NSMutableSet *reportedCallUUIDs;
@property (nonatomic, strong) AVAudioPlayer *ringbackPlayer;
@property (nonatomic, strong) NSUUID *currentCallUUID;
@property (nonatomic, strong) NSMutableDictionary *activeCalls;
@property (nonatomic, strong) CXCallController *callController;
@property (nonatomic, strong) CXProvider *provider;
@property (nonatomic, assign) pjsua_call_id currentCallIdentifier;
@property (nonatomic, assign) pjsua_call_id incoming_call_id;
@property (nonatomic, strong) NSString *currentCallId;

// Методы работы с PJSIP
- (pj_status_t) configurePJSIP;
- (BOOL) activateSoundDevice;
- (BOOL) makeCall:(NSString *)str;
- (void) changeOutputAudioPort:(AVAudioSessionPortOverride)port;
- (void) configureIncomingCall:(void (^)(void))block;
- (void) configureStarCall:(void (^)(void))block;
- (void) configureEndCall:(void (^)(void))block;
- (BOOL) acceptCall;
- (BOOL) declineCall;
- (BOOL) stopCall;
- (BOOL) isRegistered;
- (BOOL) reRegister;
- (BOOL) hangupCall;
- (BOOL) answerCall;

// Метод для получения информации о текущем звонящем
- (NSString*)getCurrentCallerInfo;
- (NSString*)displayNameForCaller:(NSString*)caller;

// CallKit Integration
- (void) setupCallKit;
- (void) reportIncomingCallWithUUID:(NSUUID *)uuid caller:(NSString *)caller forCallId:(pjsua_call_id)callId;
- (void) endCallWithUUID:(NSUUID *)uuid;
- (void) connectedCallWithUUID:(NSUUID *)uuid;
- (NSUUID *) getCurrentCallUUID;

// VoIP Push Notification Support
- (void) registerForVoIPPushes;
- (void) handlePushNotificationPayload:(NSDictionary *)payload;
- (void) handlePushDict:(NSDictionary *)payload;
- (NSDictionary *) lastReceivedPushPayload;

- (void)sendCallKit_incomingCall:(NSString *)name number:(NSString *)number callId:(NSString *)callId sessionId:(NSString *)sessionId contactIdentifier:(NSString *)contactIdentifier;

// Методы для управления звуком
- (void)startRingback;
- (void)stopRingback;
- (void)configureAudioSession;
- (void)configureAudioRouting;

@end

#endif /* PJSIPIntegration_h */
