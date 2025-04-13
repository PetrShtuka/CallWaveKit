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
@property (nonatomic, strong) NSMutableSet *reportedCallUUIDs;
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

@end

#endif /* PJSIPIntegration_h */
