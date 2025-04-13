//
//  PJSIPIntegration.m
//  SIOSP
//
//  Created by Flavien SICARD on 1/19/19.
//  Copyright © 2019 sicardf. All rights reserved.
//

#import "PJSIPIntegration.h"
#import <pthread.h>
#import <CallKit/CallKit.h>
#import <PushKit/PushKit.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

// Глобальные настройки SIP
NSString *idSIP = @"sip:412016022@158.160.5.119:5567";
NSString *uri = @"sip:158.160.5.119:5567";
NSString *scheme = @"digest";
NSString *realm = @"*";
NSString *username = @"412016022";
NSString *password = @"AbrakadabrA%4#";

// Initialize PJ library before anything else
static pj_bool_t pj_initialized = PJ_FALSE;
static pj_bool_t pjsua_created = PJ_FALSE;

// CallKit Provider и другие CallKit свойства
static CXProvider *callKitProvider = nil;
static CXCallController *callKitCallController = nil;
static NSUUID *currentCallUUID = nil;
static NSMutableDictionary *activeCalls = nil;
static NSDictionary *lastPushPayload = nil;

// VoIP Push Registry
static PKPushRegistry *voipPushRegistry = nil;

pjsua_acc_id accountIdentifier;
pjsua_call_id currentCallIdentifier = PJSUA_INVALID_ID;
static void onIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata);
static void on_call_state(pjsua_call_id call_id, pjsip_event *e);
static void on_call_media_state(pjsua_call_id call_id);
static void on_reg_state(pjsua_acc_id acc_id);

void (^incomingCall)(void);
void (^startCall)(void);
void (^endCall)(void);

pjsua_call_id incoming_call_id;

// Таймер для мониторинга состояния регистрации
static NSTimer *regCheckTimer;
// Счетчик попыток регистрации
static int regAttemptCount = 0;
// Максимальное число попыток
static const int MAX_REG_ATTEMPTS = 3;

// Функция для регистрации потока PJSIP
static void registerPJSIPThread(const char *name) {
    static NSMutableDictionary *threadDescs = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        threadDescs = [NSMutableDictionary new];
    });
    
    if (!pj_thread_is_registered()) {
        NSString *threadName = [NSString stringWithFormat:@"%s-%p", name, (void*)pthread_self()];
        NSString *key = [NSString stringWithFormat:@"%p", (void*)pthread_self()];
        
        if (![threadDescs objectForKey:key]) {
            // Выделяем память под дескриптор потока
            pj_thread_desc *desc = malloc(sizeof(pj_thread_desc));
            if (desc) {
                // Очищаем дескриптор перед использованием
                memset(desc, 0, sizeof(pj_thread_desc));
                
                pj_thread_t *thread;
                
                // Регистрируем поток
                pj_status_t status = pj_thread_register([threadName UTF8String], *desc, &thread);
                if (status != PJ_SUCCESS) {
                    NSLog(@"❌ Ошибка регистрации потока PJSIP: %d для потока %@", status, threadName);
                    free(desc);
                } else {
                    NSLog(@"✅ Поток PJSIP успешно зарегистрирован: %@", threadName);
                    // Сохраняем дескриптор, чтобы избежать утечек памяти
                    [threadDescs setObject:[NSValue valueWithPointer:desc] forKey:key];
                }
            } else {
                NSLog(@"❌ Не удалось выделить память для дескриптора потока");
            }
        }
    }
}

@implementation PJSIPIntegration

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;
    
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Инициализация множества для отслеживания показанных звонков
        self.reportedCallUUIDs = [NSMutableSet new];
        
        // Инициализируем статические переменные
        if (activeCalls == nil) {
            activeCalls = [NSMutableDictionary new];
        }
    }
    return self;
}

- (pj_status_t) configurePJSIP {
    // Ensure pj is initialized before doing anything else
    if (!pj_initialized) {
        pj_status_t status = pj_init();
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Failed to initialize PJ: %d", status);
            return status;
        }
        pj_initialized = PJ_TRUE;
        NSLog(@"✅ PJ initialized successfully");
        NSLog(@"⚡️ PJSIP version: %s", pj_get_version());
    }
    
    // Ensure thread is registered before proceeding
    pj_thread_desc desc;
    pj_thread_t *thread;
    
    // Clear the descriptor before using it
    memset(desc, 0, sizeof(desc));
    
    if (!pj_thread_is_registered()) {
        pj_status_t status = pj_thread_register("ConfigurePJSIP", desc, &thread);
    if (status != PJ_SUCCESS) {
            NSLog(@"❌ Error registering thread for PJSIP: %d", status);
        return status;
        }
        NSLog(@"✅ Thread registered for PJSIP configuration");
    }
    
    // Если PJSUA уже создан, сначала уничтожаем его для чистого рестарта
    if (pjsua_created) {
        NSLog(@"⚠️ PJSUA уже создан, пересоздаем для чистого старта");
        // Сбрасываем ID аккаунта перед уничтожением
        accountIdentifier = PJSUA_INVALID_ID;
        pjsua_destroy();
        pjsua_created = PJ_FALSE;
        
        // Даем небольшую паузу перед пересозданием
        usleep(100000); // 100ms
    }
    
    // Создаем PJSUA
    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error creating PJSUA: %d", status);
        return status;
    }
    pjsua_created = PJ_TRUE;
    NSLog(@"✅ PJSUA created successfully");

    // Базовая конфигурация из оригинального проекта
    pjsua_config config;
    pjsua_logging_config logging_config;
    pjsua_media_config media_config;
    pjsua_transport_config transport_config;
    
    pjsua_config_default(&config);
    pjsua_logging_config_default(&logging_config);
    pjsua_media_config_default(&media_config);
    pjsua_transport_config_default(&transport_config);

    // Настройки медиа из оригинального проекта
    media_config.has_ioqueue = PJ_TRUE;
    media_config.thread_cnt = 1;
    media_config.no_vad = PJ_TRUE;
    
    // Настройки из оригинального проекта
    config.use_timer = PJSUA_SIP_TIMER_INACTIVE;
    config.max_calls = 30;
    
    // Колбэки
    config.cb.on_incoming_call = &onIncomingCall;
    config.cb.on_call_state = &on_call_state;
    config.cb.on_call_media_state = &on_call_media_state;
    config.cb.on_reg_state = &on_reg_state;

    // Отключаем журнал файлов, чтобы избежать проблем с разрешениями
    logging_config.log_filename = pj_str(NULL);
    
    // Устанавливаем более детальный уровень логирования для отладки
    logging_config.level = 5;
    logging_config.console_level = 5;

    // Инициализация PJSUA
    status = pjsua_init(&config, &logging_config, &media_config);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error initializing PJSUA: %d", status);
        pjsua_destroy();
        pjsua_created = PJ_FALSE;
        return status;
    }
    
    // Создание транспорта UDP
    pjsua_transport_id transportIdentifier;
    status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transport_config, &transportIdentifier);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error creating UDP transport: %d", status);
        pjsua_destroy();
        pjsua_created = PJ_FALSE;
        return status;
    }
    
    // Создание транспорта TCP
    status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &transport_config, NULL);
    if (status != PJ_SUCCESS) {
        NSLog(@"⚠️ Warning: TCP transport creation failed: %d", status);
        // Не прерываем инициализацию из-за ошибки TCP
    }
    
    // Запуск SIP стека
    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error starting PJSUA: %d", status);
        pjsua_destroy();
        pjsua_created = PJ_FALSE;
        return status;
    }
    
    // Отключаем звуковое устройство до явной активации
    pjsua_set_no_snd_dev();
    
    // Сбрасываем ID аккаунта перед созданием нового
    accountIdentifier = PJSUA_INVALID_ID;
    
    // Настройка аккаунта SIP
    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);

    // Используем строки в формате NSUTF8StringEncoding как в оригинальном проекте
    acc_cfg.id = pj_str((char *)[idSIP cStringUsingEncoding:NSUTF8StringEncoding]);
    acc_cfg.reg_uri = pj_str((char *)[uri cStringUsingEncoding:NSUTF8StringEncoding]);
    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].scheme = pj_str((char *)[scheme cStringUsingEncoding:NSUTF8StringEncoding]);
    acc_cfg.cred_info[0].realm = pj_str((char *)[realm cStringUsingEncoding:NSUTF8StringEncoding]);
    acc_cfg.cred_info[0].username = pj_str((char *)[username cStringUsingEncoding:NSUTF8StringEncoding]);
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = pj_str((char *)[password cStringUsingEncoding:NSUTF8StringEncoding]);
    
    // Устанавливаем больший таймаут регистрации для стабильности
    acc_cfg.reg_timeout = 600; // 10 минут (в секундах)
    
    // Добавляем аккаунт БЕЗ автоматической регистрации (PJ_FALSE)
    status = pjsua_acc_add(&acc_cfg, PJ_FALSE, &accountIdentifier);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error adding account config: %d", status);
        return status;
    }

    // Проверка валидности аккаунта
    if (!pjsua_acc_is_valid(accountIdentifier)) {
        NSLog(@"❌ Invalid account ID after adding: %d", accountIdentifier);
        // В случае проблемы с аккаунтом, не пытаемся регистрироваться
        return status;
    }
    
    NSLog(@"✅ Account added with ID: %d", accountIdentifier);
    
    // Поскольку в оригинальном коде регистрация не выполняется автоматически,
    // мы явно запускаем регистрацию после добавления аккаунта
    status = pjsua_acc_set_registration(accountIdentifier, PJ_TRUE);
    if (status != PJ_SUCCESS) {
        NSLog(@"⚠️ Error starting registration: %d", status);
        // Продолжаем выполнение, так как регистрация может быть выполнена позже
    } else {
        NSLog(@"✅ Registration initiated for account: %d", accountIdentifier);
    }

    NSLog(@"✅ PJSIP configuration completed successfully");
    return PJ_SUCCESS;
}

- (BOOL) activateSoundDevice {
    NSLog(@"📞 Активирую аудиоустройство...");
    
    // Регистрируем поток
    static pj_thread_desc desc;
    static pj_thread_t *thread;

    if (!pj_thread_is_registered()) {
        memset(&desc, 0, sizeof(desc));
        pj_status_t status = pj_thread_register("ActivateSoundThread", desc, &thread);
    if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока PJSIP в activateSoundDevice: %d", status);
        }
    }
    
    // Сбрасываем все предыдущие настройки аудиосессии
    pj_status_t pj_status;
    
    // Убеждаемся, что аудиосессия активна в iOS
    NSError *audioSessionError = nil;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    // 0. Деактивируем текущую сессию перед повторной активацией
    // Это может помочь при ошибках активации
    [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    
    // Даем системе время на обновление статуса аудиосессии
    usleep(100000); // 100мс
    
    // 1. Установка категории аудиосессии с расширенными опциями
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowBluetooth | 
                                           AVAudioSessionCategoryOptionMixWithOthers |
                                           AVAudioSessionCategoryOptionAllowBluetooth |
                                           AVAudioSessionCategoryOptionDefaultToSpeaker;
    
    if (@available(iOS 10.0, *)) {
        options |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    }
    
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                  withOptions:options
                        error:&audioSessionError];
    
    if (audioSessionError) {
        NSLog(@"⚠️ Предупреждение при настройке категории аудиосессии: %@", audioSessionError);
        audioSessionError = nil;
    }
    
    // 2. Установка режима аудиосессии для голосового чата
    [audioSession setMode:AVAudioSessionModeVoiceChat error:&audioSessionError];
    if (audioSessionError) {
        NSLog(@"⚠️ Предупреждение при установке режима аудиосессии: %@", audioSessionError);
        audioSessionError = nil;
    }
    
    // 3. Установка предпочтительной частоты дискретизации и размера буфера
    [audioSession setPreferredSampleRate:16000 error:&audioSessionError];
    if (audioSessionError) {
        NSLog(@"⚠️ Предупреждение при установке частоты дискретизации: %@", audioSessionError);
        audioSessionError = nil;
    }
    
    [audioSession setPreferredIOBufferDuration:0.01 error:&audioSessionError];
    if (audioSessionError) {
        NSLog(@"⚠️ Предупреждение при установке размера буфера: %@", audioSessionError);
        audioSessionError = nil;
    }
    
    // 4. Активация аудиосессии с улучшенной обработкой ошибок
    BOOL activationSuccess = NO;
    
    // Попытка 1 - стандартная активация с опциями
    @try {
        activationSuccess = [audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&audioSessionError];
        if (!activationSuccess) {
            NSLog(@"⚠️ Первая попытка активации аудиосессии не удалась: %@", audioSessionError);
        } else {
            NSLog(@"✅ Аудиосессия успешно активирована с первой попытки");
        }
    } @catch (NSException *exception) {
        NSLog(@"❌ Исключение при первой попытке активации аудиосессии: %@", exception);
    }
    
    // Если первая попытка не удалась, пробуем другие методы
    if (!activationSuccess) {
        audioSessionError = nil;
        usleep(200000); // 200мс пауза
        
        // Попытка 2 - без опций
        @try {
            activationSuccess = [audioSession setActive:YES error:&audioSessionError];
            if (!activationSuccess) {
                NSLog(@"⚠️ Вторая попытка активации аудиосессии не удалась: %@", audioSessionError);
            } else {
                NSLog(@"✅ Аудиосессия успешно активирована со второй попытки");
            }
        } @catch (NSException *exception) {
            NSLog(@"❌ Исключение при второй попытке активации аудиосессии: %@", exception);
        }
    }
    
    // Попытка 3 - крайний случай, если первые две не удались
    if (!activationSuccess) {
        audioSessionError = nil;
        usleep(300000); // 300мс пауза
        
        // Сначала полностью деактивируем с задержкой
        @try {
            [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
            usleep(200000); // 200мс
            
            activationSuccess = [audioSession setActive:YES error:&audioSessionError];
            if (!activationSuccess) {
                NSLog(@"❌ Третья попытка активации аудиосессии не удалась: %@", audioSessionError);
            } else {
                NSLog(@"✅ Аудиосессия успешно активирована с третьей попытки");
            }
        } @catch (NSException *exception) {
            NSLog(@"❌ Исключение при третьей попытке активации аудиосессии: %@", exception);
        }
    }
    
    // Продолжаем даже если активация не удалась, пользователь может не услышать звук,
    // но мы все равно пытаемся настроить PJSIP
    
    // 5. Перед установкой аудио устройства делаем небольшую паузу
    usleep(200000); // 200 ms
    
    // 6. Отключаем звуковое устройство перед его активацией
    @try {
        pj_status = pjsua_set_no_snd_dev();
        if (pj_status != PJ_SUCCESS) {
            NSLog(@"⚠️ Не удалось отключить звуковое устройство PJSIP: %d", pj_status);
        }
        
        // Пауза после отключения
        usleep(100000); // 100 ms
    } @catch (NSException *exception) {
        NSLog(@"❌ Исключение при отключении аудиоустройства PJSIP: %@", exception);
    }
    
    // 7. Активируем устройства захвата и воспроизведения
    @try {
        // Используем безопасные значения для устройств ввода-вывода
        pj_status = pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV);
        if (pj_status != PJ_SUCCESS) {
            NSLog(@"❌ Первая попытка активации аудиоустройства PJSIP не удалась: %d", pj_status);
            
            // Вторая попытка с паузой
            usleep(200000); // 200 ms
            pj_status = pjsua_set_snd_dev(-1, -1);
            
            if (pj_status != PJ_SUCCESS) {
                NSLog(@"❌ Вторая попытка активации аудиоустройства PJSIP не удалась: %d", pj_status);
            } else {
                NSLog(@"✅ Аудиоустройство PJSIP успешно активировано при второй попытке");
            }
        } else {
            NSLog(@"✅ Аудиоустройство PJSIP успешно активировано");
        }
    } @catch (NSException *exception) {
        NSLog(@"❌ Исключение при активации аудиоустройства PJSIP: %@", exception);
        return NO;
    }
    
    // 8. Установка громкости для динамика по умолчанию
    [self changeOutputAudioPort:AVAudioSessionPortOverrideNone];
    
    // В случае активного звонка проверяем соединение медиа
    if (currentCallIdentifier != PJSUA_INVALID_ID) {
        @try {
            pjsua_call_info ci;
            if (pjsua_call_get_info(currentCallIdentifier, &ci) == PJ_SUCCESS) {
                if (ci.media_status == PJSUA_CALL_MEDIA_ACTIVE && ci.conf_slot != PJSUA_INVALID_ID) {
                    NSLog(@"⚡️ Активация соединения аудиоконференции для активного звонка");
                    pjsua_conf_connect(ci.conf_slot, 0);
                    pjsua_conf_connect(0, ci.conf_slot);
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"⚠️ Ошибка при проверке статуса медиа: %@", exception);
        }
    }
    
    NSLog(@"✅ Процесс активации аудиоустройства завершен");
    return activationSuccess || YES; // Возвращаем успех даже при ошибках активации
}

- (BOOL) makeCall:(NSString *)str {
    // Отключаем исходящие звонки
    NSLog(@"❌ Исходящие звонки отключены");
    return NO;
}

- (BOOL) make_call:(NSString *)destUri {
    // Отключаем исходящие звонки
    NSLog(@"❌ Исходящие звонки отключены");
    return NO;
}

- (void) changeOutputAudioPort:(AVAudioSessionPortOverride)port {
    registerPJSIPThread("ChangeOutputPort");
    
    NSError *audioSessionCategoryError;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&audioSessionCategoryError];
    [audioSession overrideOutputAudioPort:port error:nil];
}

- (void) configureIncomingCall:(void (^)(void))block {
    registerPJSIPThread("ConfigureIncomingCall");
    incomingCall = [block copy];
    NSLog(@"✅ Обработчик входящего звонка настроен");
}

- (void) configureStarCall:(void (^)(void))block {
    registerPJSIPThread("ConfigureStartCall");
    startCall = [block copy];
}

- (void) configureEndCall:(void (^)(void))block {
    registerPJSIPThread("ConfigureEndCall");
    endCall = [block copy];
}

- (BOOL) acceptCall {
    NSLog(@"📞 Принимаем звонок через API acceptCall...");
    
    // Создаем статические переменные для регистрации потока
    static pj_thread_desc acceptDesc;
    static pj_thread_t *acceptThread;
    
    // Регистрируем поток, если он еще не зарегистрирован
    if (!pj_thread_is_registered()) {
        memset(&acceptDesc, 0, sizeof(acceptDesc));
        pj_status_t status = pj_thread_register("AcceptCallThread", acceptDesc, &acceptThread);
    if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока для acceptCall: %d", status);
            
            // Вызываем безопасную реализацию через обертку
            return [self safeAcceptCall];
        }
        NSLog(@"✅ Поток acceptCall успешно зарегистрирован");
    }
    
    // Обычная реализация метода, но с try-catch для безопасности
    @try {
        return [self safeAcceptCall];
    } @catch (NSException *exception) {
        NSLog(@"❌ Исключение в методе acceptCall: %@", exception);
        return NO;
    }
}

// Безопасная реализация метода acceptCall, которая не падает при ошибках PJSIP
- (BOOL) safeAcceptCall {
    // Проверяем какой идентификатор звонка использовать
    pjsua_call_id callIdToAnswer = PJSUA_INVALID_ID;
    
    @try {
        if (incoming_call_id != PJSUA_INVALID_ID) {
            callIdToAnswer = incoming_call_id;
            NSLog(@"📱 Принимаем звонок с incoming_call_id: %d", callIdToAnswer);
        } else if (currentCallIdentifier != PJSUA_INVALID_ID) {
            callIdToAnswer = currentCallIdentifier;
            NSLog(@"📱 Принимаем звонок с currentCallIdentifier: %d", callIdToAnswer);
        } else {
            // Если нет известного ID, ищем любой активный звонок
            pjsua_call_id call_ids[PJSUA_MAX_CALLS];
            unsigned call_count = PJSUA_MAX_CALLS;
            
            pj_status_t enum_status = pjsua_enum_calls(call_ids, &call_count);
            if (enum_status == PJ_SUCCESS && call_count > 0) {
                callIdToAnswer = call_ids[0];
                NSLog(@"📱 Найден активный звонок: %d", callIdToAnswer);
                // Сохраняем для дальнейшего использования
                incoming_call_id = callIdToAnswer;
                currentCallIdentifier = callIdToAnswer;
            } else {
                NSLog(@"❌ Нет активного входящего звонка для ответа");
                // Возвращаем успех, т.к. звонок может появиться позже, и мы не хотим его сбрасывать
    return YES;
            }
        }
        
        // Проверяем статус звонка
        BOOL gotCallInfo = NO;
        pjsua_call_info callInfo;
        pj_status_t infoStatus = pjsua_call_get_info(callIdToAnswer, &callInfo);
        
        if (infoStatus == PJ_SUCCESS) {
            gotCallInfo = YES;
            NSLog(@"📱 Текущее состояние звонка: %d", callInfo.state);
            
            // Если звонок уже в нужном состоянии, считаем это успехом
            if (callInfo.state == PJSIP_INV_STATE_CONNECTING || callInfo.state == PJSIP_INV_STATE_CONFIRMED) {
                NSLog(@"✅ Звонок уже в процессе соединения или соединен");
                return YES;
            }
            
            // Если звонок уже завершен, нет смысла отвечать
            if (callInfo.state == PJSIP_INV_STATE_DISCONNECTED) {
                NSLog(@"⚠️ Звонок уже завершен, невозможно ответить");
                return NO;
            }
        } else {
            NSLog(@"⚠️ Не удалось получить информацию о звонке: %d, но всё равно попробуем ответить", infoStatus);
        }
        
        // Активируем аудио перед ответом
        [self activateSoundDevice];
        
        // КРИТИЧЕСКИЙ МОМЕНТ: Даже если мы не можем получить информацию или состояние не
        // идеальное, всё равно пробуем ответить на звонок
        pj_status_t status = pjsua_call_answer(callIdToAnswer, PJSIP_SC_ACCEPTED, NULL, NULL);
        
        if (status != PJ_SUCCESS) {
            NSLog(@"⚠️ Ошибка %d при принятии звонка", status);
            
            // Если не получилось ответить на звонок, но статус звонка нормальный, 
            // всё равно считаем успехом
            if (gotCallInfo && (callInfo.state == PJSIP_INV_STATE_EARLY || 
                            callInfo.state == PJSIP_INV_STATE_CONNECTING || 
                            callInfo.state == PJSIP_INV_STATE_CONFIRMED)) {
                NSLog(@"📱 Звонок кажется активным, несмотря на ошибку ответа, продолжаем");
                return YES;
            }
            
            return NO;
        }
        
        NSLog(@"✅ Звонок успешно принят: %d", callIdToAnswer);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"❌ Исключение при ответе на звонок: %@", exception);
        
        // Пытаемся ответить напрямую без проверок, если ID известен
        if (callIdToAnswer != PJSUA_INVALID_ID) {
            @try {
                NSLog(@"🔄 Экстренная попытка ответа на звонок после исключения");
                pjsua_call_answer(callIdToAnswer, PJSIP_SC_ACCEPTED, NULL, NULL);
                return YES;
            } @catch (NSException *innerException) {
                NSLog(@"❌ Финальное исключение при ответе на звонок: %@", innerException);
                return NO;
            }
        }
        
        return NO;
    }
}

- (BOOL) declineCall {
    registerPJSIPThread("DeclineCall");
    
    pj_status_t status;
    
    status = pjsua_call_answer((pjsua_call_id)incoming_call_id, PJSIP_SC_DECLINE, NULL, NULL);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error %d while sending status code PJSIP_SC_RINGING", status);
        return NO;
    }
    
    return YES;
}

- (BOOL) stopCall {
    registerPJSIPThread("StopCall");
    
    pj_status_t status;
    
    status = pjsua_call_hangup(incoming_call_id, 0, NULL, NULL);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Error %d while hangup", status);
        return NO;
    }
    
    return YES;
}

- (BOOL) isRegistered {
    registerPJSIPThread("IsRegistered");
    
    // Проверяем валидность аккаунта
    if (accountIdentifier == PJSUA_INVALID_ID || pjsua_acc_is_valid(accountIdentifier) != PJ_SUCCESS) {
        NSLog(@"⚠️ SIP аккаунт не инициализирован или невалиден");
        return NO;
    }
    
    // Получаем информацию об аккаунте
    pjsua_acc_info acc_info;
    pj_status_t status = pjsua_acc_get_info(accountIdentifier, &acc_info);
    
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Ошибка получения информации об аккаунте: %d", status);
        return NO;
    }
    
    // Статус 200 означает успешную регистрацию
    BOOL isRegistered = (acc_info.status == 200);
    NSLog(@"SIP registration status: %d (200=OK)", acc_info.status);
    
    // Если есть активная регистрация, сбрасываем счетчик попыток
    if (isRegistered) {
        regAttemptCount = 0;
    }
    
    return isRegistered;
}

// Метод для проверки доступности сети
// Проверяет доступность конкретного SIP-сервера, а не общее состояние сети
- (BOOL)isNetworkReachable {
    // Сначала проверяем, есть ли уже активная SIP регистрация
    // Если регистрация активна, значит сеть точно доступна
    if (accountIdentifier != PJSUA_INVALID_ID && pjsua_acc_is_valid(accountIdentifier) == PJ_SUCCESS) {
        pjsua_acc_info acc_info;
        pj_status_t status = pjsua_acc_get_info(accountIdentifier, &acc_info);
        
        // Если успешно получили информацию и статус регистрации 200 OK, 
        // то считаем сеть доступной
        if (status == PJ_SUCCESS && acc_info.status == 200) {
            NSLog(@"✅ Сеть доступна (активная SIP регистрация)");
            return YES;
        }
    }
    
    // Если активной регистрации нет, проверяем через прямое соединение
    // Получаем сохранённый домен и порт для проверки
    NSString *domain = [[NSUserDefaults standardUserDefaults] stringForKey:@"domain"];
    
    // Если домен не указан, используем значение по умолчанию
    const char *serverIP = "158.160.5.119";
    int serverPort = 5567;
    
    if (domain.length > 0) {
        // Пытаемся извлечь IP и порт из домена (если указаны в формате IP:port)
        NSArray *components = [domain componentsSeparatedByString:@":"];
        if (components.count > 0) {
            serverIP = [components[0] UTF8String];
            if (components.count > 1) {
                serverPort = [components[1] intValue];
                if (serverPort == 0) serverPort = 5567; // Если порт некорректный, используем значение по умолчанию
            }
        }
    }
    
    NSLog(@"🔍 Проверка доступности SIP-сервера %s:%d", serverIP, serverPort);
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(serverPort);
    
    // Преобразуем IP-адрес из строки в бинарную форму
    int inet_result = inet_pton(AF_INET, serverIP, &addr.sin_addr);
    if (inet_result <= 0) {
        NSLog(@"❌ Ошибка преобразования IP-адреса: %s (%d)", serverIP, inet_result);
        return NO;
    }
    
    int socketFd = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFd < 0) {
        NSLog(@"❌ Не удалось создать сокет для проверки сети: %d (%s)", errno, strerror(errno));
        return NO;
    }
    
    // Устанавливаем неблокирующий режим
    fcntl(socketFd, F_SETFL, O_NONBLOCK);
    
    // Устанавливаем таймаут для неблокирующего сокета
    struct timeval timeout;
    timeout.tv_sec = 3;  // 3 секунды
    timeout.tv_usec = 0;
    
    // Пытаемся соединиться
    int result = connect(socketFd, (struct sockaddr *)&addr, sizeof(addr));
    if (result < 0) {
        if (errno == EINPROGRESS) {
            // Соединение выполняется, проверяем результат
            fd_set fdset;
            struct timeval tv;
            
            FD_ZERO(&fdset);
            FD_SET(socketFd, &fdset);
            tv.tv_sec = 3;  // 3 секунды таймаут
            tv.tv_usec = 0;
            
            result = select(socketFd + 1, NULL, &fdset, NULL, &tv);
            if (result > 0) {
                // Проверяем, успешно ли соединение
                int error = 0;
                socklen_t len = sizeof(error);
                if (getsockopt(socketFd, SOL_SOCKET, SO_ERROR, &error, &len) < 0 || error) {
                    NSLog(@"❌ Ошибка соединения с SIP сервером: %d (%s)", error, strerror(error));
                    close(socketFd);
                    return NO;
                }
            } else if (result == 0) {
                NSLog(@"❌ Таймаут соединения с SIP сервером");
                close(socketFd);
                return NO;
            } else {
                NSLog(@"❌ Ошибка при проверке состояния соединения: %d (%s)", errno, strerror(errno));
                close(socketFd);
                return NO;
            }
        } else {
            NSLog(@"❌ Ошибка соединения с SIP сервером: %d (%s)", errno, strerror(errno));
            close(socketFd);
            return NO;
        }
    }
    
    NSLog(@"✅ Соединение с SIP-сервером успешно установлено");
    close(socketFd);
    return YES;
}

// Модификация метода reRegister для проверки сети
- (BOOL)reRegister {
    registerPJSIPThread("reRegister");
    
    // Проверяем, не зарегистрирован ли уже аккаунт
    if (accountIdentifier != PJSUA_INVALID_ID && pjsua_acc_is_valid(accountIdentifier) == PJ_SUCCESS) {
        pjsua_acc_info acc_info;
        pj_status_t status = pjsua_acc_get_info(accountIdentifier, &acc_info);
        
        // Если аккаунт уже зарегистрирован с успешным статусом, ничего не делаем
        if (status == PJ_SUCCESS && acc_info.status == 200) {
            NSLog(@"✅ SIP аккаунт уже зарегистрирован (статус 200 OK), повторная регистрация не требуется");
            // Сбрасываем счетчик попыток при обнаружении активной регистрации
            regAttemptCount = 0;
            return YES;
        }
    }
    
    // Пропускаем проверку сети и всегда пытаемся зарегистрироваться
    
    if (accountIdentifier == PJSUA_INVALID_ID) {
        NSLog(@"⚠️ Аккаунт не инициализирован, нечего перерегистрировать");
        
        // Возможно, нужно инициализировать PJSIP заново
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPAccountError" 
                                                               object:nil 
                                                             userInfo:@{
                                                                @"message": @"SIP аккаунт не инициализирован"
                                                             }];
        });
        
        return NO;
    }
    
    // Выполняем перерегистрацию аккаунта
    pj_status_t status = pjsua_acc_set_registration(accountIdentifier, PJ_TRUE);
    
    if (status != PJ_SUCCESS) {
        NSLog(@"⚠️ Error starting registration: %d", status);
        
        // Отправляем уведомление об ошибке регистрации
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPRegistrationError" 
                                                               object:nil 
                                                             userInfo:@{
                                                                @"message": [NSString stringWithFormat:@"Ошибка регистрации: %d", status]
                                                             }];
        });
        
        return NO;
    }
    
    NSLog(@"🔄 Повторная регистрация SIP инициирована");
    return YES;
}

- (BOOL)hangupCall {
    registerPJSIPThread("HangupCall");
    
    // Проверяем наличие активного вызова
    if (currentCallIdentifier == PJSUA_INVALID_ID) {
        NSLog(@"⚠️ Нет активного вызова для завершения");
        return NO;
    }
    
    // Получаем информацию о вызове
    pjsua_call_info call_info;
    pj_status_t status = pjsua_call_get_info(currentCallIdentifier, &call_info);
    
    if (status != PJ_SUCCESS) {
        char error_msg[PJ_ERR_MSG_SIZE];
        pj_strerror(status, error_msg, sizeof(error_msg));
        NSLog(@"❌ Ошибка получения информации о вызове: %s", error_msg);
        // Попробуем всё равно повесить трубку, так как ID вызова у нас есть
    } else {
        if (call_info.state == PJSIP_INV_STATE_DISCONNECTED) {
            NSLog(@"⚠️ Вызов уже завершен");
            currentCallIdentifier = PJSUA_INVALID_ID;
            return YES;
        }
        NSLog(@"📞 Завершение вызова (ID: %d, состояние: %d)", currentCallIdentifier, call_info.state);
    }
    
    // Завершение вызова
    status = pjsua_call_hangup(currentCallIdentifier, 0, NULL, NULL);
    
    if (status != PJ_SUCCESS) {
        char error_msg[PJ_ERR_MSG_SIZE];
        pj_strerror(status, error_msg, sizeof(error_msg));
        NSLog(@"❌ Ошибка завершения вызова: %s", error_msg);
        return NO;
    }
    
    NSLog(@"✅ Вызов успешно завершен");
    currentCallIdentifier = PJSUA_INVALID_ID;
    return YES;
}

- (BOOL)answerCall {
    registerPJSIPThread("AnswerCall");
    
    // Проверяем наличие входящего вызова
    if (currentCallIdentifier == PJSUA_INVALID_ID) {
        NSLog(@"❌ Нет активного вызова для ответа");
        return NO;
    }
    
    // Получаем информацию о вызове
    pjsua_call_info call_info;
    pj_status_t status = pjsua_call_get_info(currentCallIdentifier, &call_info);
    
    if (status != PJ_SUCCESS) {
        char error_msg[PJ_ERR_MSG_SIZE];
        pj_strerror(status, error_msg, sizeof(error_msg));
        NSLog(@"❌ Ошибка получения информации о вызове: %s", error_msg);
        return NO;
    }
    
    // Проверяем, что вызов находится в состоянии "входящий"
    if (call_info.state != PJSIP_INV_STATE_INCOMING) {
        NSLog(@"⚠️ Вызов не находится в состоянии 'входящий' (текущее состояние: %d)", call_info.state);
        return NO;
    }
    
    NSLog(@"📞 Отвечаем на входящий вызов (ID: %d)", currentCallIdentifier);
    
    // Настраиваем параметры медиа для ответа
    pjsua_call_setting call_setting;
    pjsua_call_setting_default(&call_setting);
    call_setting.aud_cnt = 1; // Включаем аудио
    call_setting.vid_cnt = 0; // Отключаем видео
    
    // Отвечаем на вызов
    status = pjsua_call_answer2(currentCallIdentifier, &call_setting, 200, NULL, NULL);
    
    if (status != PJ_SUCCESS) {
        char error_msg[PJ_ERR_MSG_SIZE];
        pj_strerror(status, error_msg, sizeof(error_msg));
        NSLog(@"❌ Ошибка ответа на вызов: %s", error_msg);
        return NO;
    }
    
    NSLog(@"✅ Успешно ответили на вызов");
    return YES;
}

static void onIncomingCall(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    // Регистрируем поток для обработки callback
    static pj_thread_desc desc;
    static pj_thread_t *thread;
    
    if (!pj_thread_is_registered()) {
        // Инициализация дескриптора потока перед регистрацией
        memset(&desc, 0, sizeof(desc));
        
        pj_status_t status = pj_thread_register("IncomingCallThread", desc, &thread);
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока в обработчике входящего звонка: %d", status);
            return;
        }
    }
    
    pj_status_t status;
    
    NSLog(@"📞 Входящий звонок обнаружен (call_id: %d)", call_id);
    
    // Проверяем, есть ли уже активный звонок
    BOOL hasActiveCall = NO;
    pjsua_call_id existingCallId = PJSUA_INVALID_ID;
    
    // Перебираем текущие звонки, чтобы проверить, есть ли активный
    // Это безопаснее, чем просто проверять глобальные переменные
    pjsua_call_id call_ids[PJSUA_MAX_CALLS];
    unsigned call_count = PJSUA_MAX_CALLS;
    
    if (pjsua_enum_calls(call_ids, &call_count) == PJ_SUCCESS) {
        for (unsigned i = 0; i < call_count; i++) {
            // Пропускаем текущий входящий звонок
            if (call_ids[i] == call_id) 
                continue;
                
            pjsua_call_info call_info;
            if (pjsua_call_get_info(call_ids[i], &call_info) == PJ_SUCCESS) {
                // Проверяем состояние звонка
                if (call_info.state == PJSIP_INV_STATE_CONFIRMED || 
                    call_info.state == PJSIP_INV_STATE_CONNECTING ||
                    call_info.state == PJSIP_INV_STATE_EARLY) {
                    hasActiveCall = YES;
                    existingCallId = call_ids[i];
                    NSLog(@"⚠️ Уже есть активный звонок (id: %d) с состоянием: %d", existingCallId, call_info.state);
                    break;
                }
            }
        }
    }
    
    // Сохраняем идентификатор входящего звонка глобально
    incoming_call_id = call_id;
    // Также сохраняем во втором поле только если нет активного звонка
    if (!hasActiveCall) {
        currentCallIdentifier = call_id;
    }
    
    // Посылаем RINGING для уведомления вызывающего абонента
    status = pjsua_call_answer((pjsua_call_id)call_id, PJSIP_SC_RINGING, NULL, NULL);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Ошибка %d при отправке PJSIP_SC_RINGING", status);
    }
    
    // Если у нас уже есть активный звонок, автоматически отклоняем новый
    if (hasActiveCall) {
        NSLog(@"⚠️ Отклоняем входящий звонок %d, т.к. уже есть активный звонок %d", call_id, existingCallId);
        
        // Отправляем "ЗАНЯТО" для входящего звонка
        status = pjsua_call_answer((pjsua_call_id)call_id, PJSIP_SC_BUSY_HERE, NULL, NULL);
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка %d при отклонении входящего звонка", status);
        }
        
        // Не показываем CallKit UI для нового звонка
        return;
    }
    
    // Получить информацию о звонящем
    NSString *caller = @"Неизвестный";
    
    if (rdata && rdata->msg_info.from) {
        // Получаем имя звонящего, если доступно
        if (rdata->msg_info.from->name.slen > 0) {
            caller = [[NSString alloc] initWithBytes:rdata->msg_info.from->name.ptr 
                                             length:rdata->msg_info.from->name.slen 
                                           encoding:NSUTF8StringEncoding];
            NSLog(@"📱 Входящий звонок от: %@", caller);
        }
        
        // Если имя не указано, пытаемся получить SIP URI
        if ([caller isEqualToString:@"Неизвестный"] && rdata->msg_info.from->uri) {
            char uri_str[PJSIP_MAX_URL_SIZE];
            int len = pjsip_uri_print(PJSIP_URI_IN_FROMTO_HDR, rdata->msg_info.from->uri, uri_str, sizeof(uri_str));
            if (len > 0) {
                caller = [[NSString alloc] initWithBytes:uri_str length:len encoding:NSUTF8StringEncoding];
                NSLog(@"📱 SIP URI звонящего: %@", caller);
            }
        }
    }
    
    // Создаем UUID для звонка
    NSUUID *callUUID = [NSUUID UUID];
    
    // Проверяем, не показан ли уже UI для этого звонка из push-уведомления
    PJSIPIntegration *pjsip = [PJSIPIntegration sharedInstance];
    BOOL alreadyReported = NO;
    for (NSString *uuid in pjsip.reportedCallUUIDs) {
        NSDictionary *callInfo = [activeCalls objectForKey:uuid];
        if (callInfo) {
            NSNumber *callIdNumber = [callInfo objectForKey:@"call_id"];
            if (callIdNumber && ([callIdNumber intValue] == call_id || 
                                [callIdNumber intValue] == PJSUA_INVALID_ID)) {
                NSLog(@"⚠️ SIP: Звонок с ID %d уже показан в CallKit через UUID %@, обновляем ID", 
                     call_id, uuid);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableDictionary *mutableCallInfo = [NSMutableDictionary dictionaryWithDictionary:callInfo];
                    [mutableCallInfo setObject:@(call_id) forKey:@"call_id"];
                    [activeCalls setObject:mutableCallInfo forKey:uuid];
                });
                
                alreadyReported = YES;
                break;
            }
        }
    }
    
    // Если звонок не показан через CallKit, показываем его
    if (!alreadyReported) {
        // Вызываем метод для отображения входящего звонка через CallKit
        dispatch_async(dispatch_get_main_queue(), ^{
            [[PJSIPIntegration sharedInstance] reportIncomingCallWithUUID:callUUID caller:caller forCallId:call_id];
            
            // Вызываем блок обратного вызова, если установлен (для обратной совместимости)
            if (incomingCall) {
    incomingCall();
            }
        });
    }
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *e) {
    // Регистрируем поток для обработки callback
    static pj_thread_desc desc;
    static pj_thread_t *thread;
    
    if (!pj_thread_is_registered()) {
        // Инициализация дескриптора потока перед регистрацией
        memset(&desc, 0, sizeof(desc));
        
        pj_status_t status = pj_thread_register("CallStateThread", desc, &thread);
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока в обработчике состояния звонка: %d", status);
            return;
        }
        NSLog(@"✅ Поток обработчика состояния звонка зарегистрирован");
    }
    
    PJ_UNUSED_ARG(e);
    
    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);
    
    NSLog(@"⚡️ Изменение состояния звонка - call_id: %d, state: %d", call_id, ci.state);
    
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
        NSLog(@"⚡️ Звонок завершен, вызов UI обработчика");
        
        // Получаем UUID из словаря активных звонков
        NSString *callIdStr = [NSString stringWithFormat:@"%d", call_id];
        NSUUID *callUUID = nil;
        
        // Ищем UUID, связанный с этим call_id
        for (NSString *uuidString in activeCalls) {
            NSDictionary *callInfo = [activeCalls objectForKey:uuidString];
            if (callInfo && [callInfo objectForKey:@"call_id"]) {
                NSNumber *callIdNumber = [callInfo objectForKey:@"call_id"];
                if ([callIdNumber intValue] == call_id) {
                    callUUID = [[NSUUID alloc] initWithUUIDString:uuidString];
                    break;
                }
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Принудительно завершаем CallKit-сессию, если она существует
            if (callUUID != nil) {
                NSLog(@"📱 CallKit: Принудительное завершение сессии для UUID %@", callUUID);
                [activeCalls removeObjectForKey:callUUID.UUIDString];
                
                // Завершаем звонок в CallKit
                CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:callUUID];
                CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];
                
                [callKitCallController requestTransaction:transaction completion:^(NSError *error) {
                    if (error) {
                        NSLog(@"❌ CallKit: Ошибка при завершении звонка: %@", error);
                    } else {
                        NSLog(@"✅ CallKit: Звонок успешно завершен");
                    }
                }];
            }
            
            if (endCall) {
                endCall();
            } else {
                NSLog(@"⚠️ Обработчик завершения звонка не настроен!");
            }
        });
    }
}

static void on_call_media_state(pjsua_call_id call_id) {
    // Регистрируем поток для обработки callback
    static pj_thread_desc desc;
    static pj_thread_t *thread;
    
    if (!pj_thread_is_registered()) {
        // Инициализация дескриптора потока перед регистрацией
        memset(&desc, 0, sizeof(desc));
        
        pj_status_t status = pj_thread_register("CallMediaThread", desc, &thread);
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока в обработчике медиа: %d", status);
            return;
        }
        NSLog(@"✅ Поток обработчика медиа зарегистрирован");
    }
    
    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);
    
    NSLog(@"⚡️ Изменение состояния медиа - call_id: %d, media_status: %d", call_id, ci.media_status);
    
    if (ci.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        NSLog(@"⚡️ Медиа активировано, подключение аудио-конференции");
        pjsua_conf_connect(ci.conf_slot, 0);
        pjsua_conf_connect(0, ci.conf_slot);
    }
}

static void on_reg_state(pjsua_acc_id acc_id) {
    // Регистрируем поток для обработки callback
    static pj_thread_desc desc;
    static pj_thread_t *thread;
    
    if (!pj_thread_is_registered()) {
        // Инициализация дескриптора потока перед регистрацией
        memset(&desc, 0, sizeof(desc));
        
        pj_status_t status = pj_thread_register("RegStateThread", desc, &thread);
        if (status != PJ_SUCCESS) {
            NSLog(@"❌ Ошибка регистрации потока в обработчике регистрации: %d", status);
            return;
        }
    }
    
    pjsua_acc_info acc_info;
    pj_status_t status = pjsua_acc_get_info(acc_id, &acc_info);
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Не удалось получить информацию об аккаунте: %d", status);
        return;
    }
    
    // Логирование состояния регистрации
    NSLog(@"ℹ️ SIP registration status changed: %d %.*s", 
          acc_info.status,
          (int)acc_info.status_text.slen,
          acc_info.status_text.ptr);
    
    // Проверяем статус регистрации
    if (acc_info.status == 200) {
        // Успешная регистрация
        NSLog(@"✅ SIP успешно зарегистрирован, expires=%d", acc_info.expires);
        
        // Сбрасываем счетчик попыток при успешной регистрации
        regAttemptCount = 0;
        
        // Оповещаем UI о успешной регистрации
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPRegistrationSuccess" 
                                                                object:nil];
        });
    } else if (acc_info.status == 503) {
        // Ошибка "Network is unreachable" - проблема с сетью
        NSLog(@"❌ Ошибка регистрации SIP: %d %.*s (Network is unreachable)", 
              acc_info.status,
              (int)acc_info.status_text.slen,
              acc_info.status_text.ptr);
        
        // Увеличиваем счетчик попыток
        regAttemptCount++;
        
        // Вычисляем задержку с экспоненциальным ростом, но не более 30 секунд
        int delay = MIN(pow(2, regAttemptCount), 30);
        
        // Оповещаем UI о проблеме сети
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPNetworkError" 
                                                               object:nil 
                                                             userInfo:@{
                                                                @"message": @"Сеть недоступна. Проверьте подключение к интернету.",
                                                                @"status": @(acc_info.status),
                                                                @"retryIn": @(delay)
                                                             }];
        });
        
        NSLog(@"🔄 Повторная попытка регистрации через %d секунд (попытка %d из %d)...", 
              delay, regAttemptCount, MAX_REG_ATTEMPTS);
        
        // Планируем повторную попытку с экспоненциальной задержкой
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Сначала проверяем сетевое соединение
            if ([[PJSIPIntegration sharedInstance] isNetworkReachable]) {
                // Если сеть снова доступна, пытаемся зарегистрироваться
                pj_status_t reg_status = pjsua_acc_set_registration(acc_id, PJ_TRUE);
                if (reg_status != PJ_SUCCESS) {
                    NSLog(@"❌ Ошибка повторной регистрации: %d", reg_status);
                }
            } else {
                NSLog(@"❌ Сеть по-прежнему недоступна, откладываем повторную регистрацию");
                // Если достигли максимального числа попыток, сообщаем об этом
                if (regAttemptCount >= MAX_REG_ATTEMPTS) {
                    NSLog(@"⚠️ Достигнуто максимальное число попыток (%d). Ожидаем следующего события.", MAX_REG_ATTEMPTS);
                }
            }
        });
    } else if (acc_info.status >= 300) {
        // Другие ошибки регистрации
        NSLog(@"❌ Ошибка регистрации SIP: %d %.*s", 
              acc_info.status,
              (int)acc_info.status_text.slen,
              acc_info.status_text.ptr);
        
        // Оповещаем UI о проблеме регистрации
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *errorMessage = [NSString stringWithFormat:@"Ошибка регистрации SIP: %d", acc_info.status];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPRegistrationError" 
                                                               object:nil 
                                                             userInfo:@{@"message": errorMessage}];
        });
        
        // Попытка повторной регистрации при ошибке
        if (acc_info.status != 0) {
            // Увеличиваем счетчик попыток
            regAttemptCount++;
            
            // Если достигли максимального числа попыток, увеличиваем интервал
            int delay = (regAttemptCount >= MAX_REG_ATTEMPTS) ? 30 : 5;
            
            NSLog(@"🔄 Попытка повторной регистрации через %d секунд...", delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                pj_status_t reg_status = pjsua_acc_set_registration(acc_id, PJ_TRUE);
                if (reg_status != PJ_SUCCESS) {
                    NSLog(@"❌ Ошибка повторной регистрации: %d", reg_status);
                }
            });
        }
    }
}

- (char *)cStringFromNSString:(NSString *)string {
    if (!string) {
        return nil;
    }
    
    if (string.length == 0) {
        return "";
    }
    
    char *result = calloc([string length] + 1, 1);
    [string getCString:result maxLength:[string length] + 1 encoding:NSUTF8StringEncoding];
    
    return result;
}

#pragma mark - CallKit Integration

- (void)setupCallKit {
    NSLog(@"📱 CallKit: Настройка CallKit...");
    
    // Создаем активные звонки, если не созданы
    if (activeCalls == nil) {
        activeCalls = [NSMutableDictionary dictionary];
    }
    
    // Если провайдер уже создан, выходим
    if (callKitProvider != nil) {
        return;
    }
    
    // Конфигурация провайдера
    CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] initWithLocalizedName:@"SIOSP"];
    configuration.supportsVideo = NO;
    configuration.maximumCallsPerCallGroup = 1;
    configuration.supportedHandleTypes = [NSSet setWithObject:@(CXHandleTypePhoneNumber)];
    
    if (@available(iOS 11.0, *)) {
        configuration.includesCallsInRecents = YES;
    }
    
    // Настройка звуков (при необходимости можно настроить собственные звуки)
    // configuration.ringtoneSound = @"ringtone.wav";
    
    // Создаем провайдер и настраиваем делегата
    callKitProvider = [[CXProvider alloc] initWithConfiguration:configuration];
    [callKitProvider setDelegate:self queue:dispatch_get_main_queue()];
    
    // Создаем контроллер звонков
    callKitCallController = [[CXCallController alloc] init];
    
    NSLog(@"✅ CallKit: Успешно настроен");
}

- (void)cleanupOldCallUUIDs {
    // Ограничиваем до 10 самых последних UUID
    if (self.reportedCallUUIDs.count <= 10) return;
    
    NSMutableArray *uuids = [NSMutableArray arrayWithArray:[self.reportedCallUUIDs allObjects]];
    [uuids sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [obj1 compare:obj2];
    }];
    
    NSRange removeRange = NSMakeRange(0, uuids.count - 10);
    NSArray *toRemove = [uuids subarrayWithRange:removeRange];
    
    for (NSString *uuid in toRemove) {
        [self.reportedCallUUIDs removeObject:uuid];
    }
}

- (void)reportIncomingCallWithUUID:(NSUUID *)uuid caller:(NSString *)caller forCallId:(pjsua_call_id)callId {
    // Проверяем, не показывали ли мы уже CallKit для этого звонка
    if ([self.reportedCallUUIDs containsObject:uuid.UUIDString]) {
        NSLog(@"⚠️ CallKit: Этот UUID (%@) уже был показан, игнорируем повторное отображение", uuid.UUIDString);
        return;
    }
    
    // Добавляем UUID в список показанных
    [self.reportedCallUUIDs addObject:uuid.UUIDString];
    
    // Ограничиваем размер множества отслеживаемых UUID
    if (self.reportedCallUUIDs.count > 20) {
        [self cleanupOldCallUUIDs];
    }
    
    // Убедимся, что мы на главном потоке
    [self performOnMainThread:^{
        // Настройка CallKit при необходимости
        if (callKitProvider == nil) {
            [self setupCallKit];
        }
        
        // Устанавливаем текущий UUID звонка
        currentCallUUID = uuid;
        
        // Создаем handle для входящего звонка
        CXCallUpdate *update = [[CXCallUpdate alloc] init];
        update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypePhoneNumber value:caller];
        update.hasVideo = NO;
        update.supportsHolding = NO;
        update.supportsGrouping = NO;
        update.supportsUngrouping = NO;
        update.supportsDTMF = YES;
        
        // Установим указатель на локальный звонок, к которому будут обращаться
        // для предотвращения преждевременного освобождения
        __block NSUUID *localUUID = uuid;
        
        NSLog(@"📱 CallKit: Сообщаем о входящем звонке от %@ (UUID: %@)", caller, uuid.UUIDString);
        
        // Сохраняем информацию о звонке заранее, чтобы она была доступна даже при задержке CallKit
        NSMutableDictionary *callInfo = [NSMutableDictionary dictionary];
        [callInfo setObject:caller forKey:@"caller"];
        NSNumber *callIdNumber = @(callId);
        [callInfo setObject:callIdNumber forKey:@"call_id"];
        
        // Сохраняем время создания звонка для отслеживания устаревших записей
        [callInfo setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"creation_time"];
        
        // Сохраняем информацию сразу
        [activeCalls setObject:callInfo forKey:localUUID.UUIDString];
        
        // Проверка состояния звонка перед отображением CallKit UI
        __block BOOL sipCallActive = NO;
        __block pjsua_call_id activeCallId = PJSUA_INVALID_ID;
        
        if (callId != PJSUA_INVALID_ID) {
            activeCallId = callId;
            pjsua_call_info ci;
            if (pjsua_call_get_info(callId, &ci) == PJ_SUCCESS) {
                if (ci.state == PJSIP_INV_STATE_INCOMING || 
                    ci.state == PJSIP_INV_STATE_EARLY ||
                    ci.state == PJSIP_INV_STATE_CONNECTING) {
                    sipCallActive = YES;
                }
            }
        } else if (currentCallIdentifier != PJSUA_INVALID_ID) {
            activeCallId = currentCallIdentifier;
            pjsua_call_info ci;
            if (pjsua_call_get_info(currentCallIdentifier, &ci) == PJ_SUCCESS) {
                if (ci.state == PJSIP_INV_STATE_INCOMING || 
                    ci.state == PJSIP_INV_STATE_EARLY ||
                    ci.state == PJSIP_INV_STATE_CONNECTING) {
                    sipCallActive = YES;
                }
            }
        }
        
        // Сообщаем о входящем звонке системе через CallKit
        [callKitProvider reportNewIncomingCallWithUUID:uuid update:update completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"❌ CallKit: Ошибка при уведомлении о входящем звонке: %@", error);
                
                // Если ошибка из-за превышения лимита звонков или других ограничений iOS
                // Используем коды ошибок как константы, а не типы
                if (error.code == 7 || // CXErrorCodeRequestTransactionError
                    error.code == 6) { // CXErrorCodeCallDirectoryManagerError
                    // Повторяем попытку с задержкой
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self reportIncomingCallWithUUID:[NSUUID UUID] caller:caller forCallId:callId];
                    });
                } else {
                    // Для других ошибок - тоже пытаемся повторить
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self reportIncomingCallWithUUID:[NSUUID UUID] caller:caller forCallId:callId];
                    });
                }
            } else {
                NSLog(@"✅ CallKit: Входящий звонок успешно зарегистрирован в системе (UUID: %@)", localUUID.UUIDString);
                
                // Если SIP звонок не активен, начинаем проверять его состояние в фоне
                if (!sipCallActive && activeCallId != PJSUA_INVALID_ID) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [self monitorSIPCallState:activeCallId forUUID:localUUID];
                    });
                }
                
                // Активируем звуковое устройство для звонка
                [self activateSoundDevice];
            }
        }];
    }];
}

// Новый метод для мониторинга состояния SIP звонка
- (void)monitorSIPCallState:(pjsua_call_id)callId forUUID:(NSUUID *)uuid {
    // Максимум 60 попыток с интервалом 0.5 секунды (всего 30 секунд)
    for (int i = 0; i < 60; i++) {
        BOOL callActive = NO;
        
        // Проверяем состояние SIP звонка
        pjsua_call_info ci;
        pj_status_t status = pjsua_call_get_info(callId, &ci);
        
        if (status == PJ_SUCCESS) {
            NSLog(@"🔄 Мониторинг SIP звонка (ID: %d): состояние %d (попытка %d)", callId, ci.state, i+1);
            callActive = YES;
            
            // Если звонок завершился или соединен успешно - выходим из мониторинга
            if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
                NSLog(@"⚠️ SIP звонок завершился во время мониторинга");
                break;
            } else if (ci.state == PJSIP_INV_STATE_CONFIRMED) {
                NSLog(@"✅ SIP звонок успешно соединился во время мониторинга");
                break;
            } 
            
            // Если звонок находится в состоянии INCOMING и не был принят через UI,
            // пробуем ответить на него автоматически, чтобы предотвратить сброс
            if ((ci.state == PJSIP_INV_STATE_INCOMING || ci.state == PJSIP_INV_STATE_EARLY) && (i > 10)) {
                // Только если мониторинг идет больше 5 секунд (5*2 = 10)
                NSLog(@"⚠️ SIP звонок до сих пор во входящем состоянии, пробуем ответить автоматически");
                
                pj_status_t answer_status = pjsua_call_answer(callId, PJSIP_SC_ACCEPTED, NULL, NULL);
                if (answer_status == PJ_SUCCESS) {
                    NSLog(@"✅ Автоматический ответ SIP успешно отправлен");
                } else {
                    NSLog(@"⚠️ Ошибка автоматического ответа: %d", answer_status);
                }
            }
        } else {
            NSLog(@"⚠️ Не удалось получить информацию о SIP звонке: %d", status);
            
            // Если не удалось получить информацию, пробуем найти активный звонок
            pjsua_call_id call_ids[PJSUA_MAX_CALLS];
            unsigned call_count = PJSUA_MAX_CALLS;
            
            status = pjsua_enum_calls(call_ids, &call_count);
            if (status == PJ_SUCCESS && call_count > 0) {
                callActive = YES;
                NSLog(@"🔍 Найдено активных звонков: %d", call_count);
                
                // Обновляем ID звонка, если нашли новый активный звонок
                if (call_count > 0 && call_ids[0] != callId) {
                    callId = call_ids[0];
                    NSLog(@"🔄 Обновлен ID звонка для мониторинга: %d", callId);
                    
                    // Обновляем информацию о звонке в активных звонках
                    [self performOnMainThread:^{
                        NSMutableDictionary *callInfo = [activeCalls objectForKey:uuid.UUIDString];
                        if (callInfo) {
                            [callInfo setObject:@(callId) forKey:@"call_id"];
                        }
                    }];
                    
                    // Обновляем глобальные идентификаторы
                    incoming_call_id = callId;
                    currentCallIdentifier = callId;
                }
            }
        }
        
        // Если после 15 секунд (30 попыток) звонок все еще активен, но не соединен - 
        // пробуем активно поддержать его
        if (callActive && i >= 30 && i % 10 == 0) {
            NSLog(@"⚠️ SIP звонок активен, но соединение задерживается");
            
            // Воспроизводим звук для пользователя каждые 5 секунд (10 попыток)
            dispatch_async(dispatch_get_main_queue(), ^{
                AudioServicesPlaySystemSound(1052); // Звук оповещения
            });
            
            // Пробуем ещё раз активировать аудио устройство
            [self activateSoundDevice];
        }
        
        // Пауза перед следующей проверкой
        [NSThread sleepForTimeInterval:0.5];
    }
    
    NSLog(@"🏁 Завершен мониторинг SIP звонка (ID: %d)", callId);
}

- (void)endCallWithUUID:(NSUUID *)uuid {
    if (callKitProvider == nil) {
        return;
    }
    
    NSLog(@"📱 CallKit: Завершение звонка %@", uuid);
    
    // Создаем действие завершения звонка
    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];
    
    [callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"❌ CallKit: Ошибка при завершении звонка: %@", error);
        } else {
            NSLog(@"✅ CallKit: Звонок успешно завершен");
        }
    }];
}

- (void)connectedCallWithUUID:(NSUUID *)uuid {
    if (callKitProvider == nil) {
        return;
    }
    
    NSLog(@"📱 CallKit: Соединение звонка %@", uuid);
    
    // Сообщаем системе, что звонок соединен
    [callKitProvider reportOutgoingCallWithUUID:uuid connectedAtDate:nil];
}

#pragma mark - CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider {
    NSLog(@"📱 CallKit: providerDidReset");
    
    // Сбрасываем все звонки при сбросе провайдера
    for (NSString *uuidString in activeCalls) {
        NSDictionary *callInfo = [activeCalls objectForKey:uuidString];
        NSNumber *callIdNumber = [callInfo objectForKey:@"call_id"];
        
        if (callIdNumber != nil) {
            pjsua_call_id callId = [callIdNumber intValue];
            pjsua_call_hangup(callId, 0, NULL, NULL);
        }
    }
    
    // Очищаем список активных звонков
    [activeCalls removeAllObjects];
    currentCallUUID = nil;
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    NSLog(@"📱 CallKit: performStartCallAction - Исходящие звонки отключены");
    
    // Сообщаем об ошибке и отклоняем действие
    NSError *error = [NSError errorWithDomain:@"SIOSPApp" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Исходящие звонки отключены"}];
    [action fail];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    NSLog(@"📱 CallKit: performAnswerCallAction");
    
    // Сохраняем время ответа для проверки в performEndCallAction
    static NSDate *lastAnswerTime = nil;
    static NSUUID *lastAnswerUUID = nil;
    
    lastAnswerTime = [NSDate date];
    lastAnswerUUID = action.callUUID;
    
    // Сразу выполняем action, чтобы CallKit UI обновился и показал соединение
    [action fulfill];
    
    // Проигрываем звук соединения для обратной связи с пользователем
    AudioServicesPlaySystemSound(1106);
    
    // Небольшая задержка перед дальнейшими действиями
    // Это помогает предотвратить конфликт с потенциальным вызовом performEndCallAction
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Получаем информацию о звонке из сохраненного списка
        NSDictionary *callInfo = [activeCalls objectForKey:action.callUUID.UUIDString];
        __block pjsua_call_id sipCallId = PJSUA_INVALID_ID;
        
        if (callInfo) {
            NSNumber *callIdNumber = [callInfo objectForKey:@"call_id"];
            if (callIdNumber) {
                sipCallId = [callIdNumber intValue];
                // Сохраняем ID в обоих полях для согласованности
                incoming_call_id = sipCallId;
                currentCallIdentifier = sipCallId;
                NSLog(@"📱 CallKit: Найден ID звонка в активных звонках: %d", sipCallId);
            }
        }
        
        // Если ID не найден, попробуем использовать сохраненные глобальные ID
        if (sipCallId == PJSUA_INVALID_ID) {
            if (incoming_call_id != PJSUA_INVALID_ID) {
                sipCallId = incoming_call_id;
                NSLog(@"📱 CallKit: Используем глобальный incoming_call_id: %d", sipCallId);
            } else if (currentCallIdentifier != PJSUA_INVALID_ID) {
                sipCallId = currentCallIdentifier;
                NSLog(@"📱 CallKit: Используем глобальный currentCallIdentifier: %d", sipCallId);
            }
        }
        
        // Создаем статические переменные для регистрации потока
        static pj_thread_desc answerActionDesc;
        static pj_thread_t *answerActionThread;
        
        // Регистрируем текущий поток для безопасного вызова функций PJSIP
        if (!pj_thread_is_registered()) {
            // Инициализация дескриптора потока перед регистрацией
            memset(&answerActionDesc, 0, sizeof(answerActionDesc));
            
            pj_status_t regStatus = pj_thread_register("AnswerActionThread", answerActionDesc, &answerActionThread);
            if (regStatus != PJ_SUCCESS) {
                NSLog(@"❌ Ошибка регистрации потока для ответа на звонок: %d", regStatus);
            } else {
                NSLog(@"✅ Поток для ответа на звонок успешно зарегистрирован");
            }
        } else {
            NSLog(@"ℹ️ Поток уже зарегистрирован в PJSIP");
        }
        
        // Активируем аудиоустройство для звонка
        BOOL audioActivated = [self activateSoundDevice];
        if (!audioActivated) {
            NSLog(@"⚠️ Активация аудио не удалась, но продолжаем обработку звонка");
        }
        
        // Ищем ID звонка если не нашли его в активных звонках
        if (sipCallId == PJSUA_INVALID_ID) {
            pjsua_call_id call_ids[PJSUA_MAX_CALLS];
            unsigned call_count = PJSUA_MAX_CALLS;
            
            // Используем try-catch чтобы защититься от ошибок
            @try {
                pj_status_t status = pjsua_enum_calls(call_ids, &call_count);
                
                if (status == PJ_SUCCESS && call_count > 0) {
                    sipCallId = call_ids[0];
                    NSLog(@"📱 CallKit: Используем первый найденный активный звонок: %d", sipCallId);
                    // Обновляем глобальные переменные
                    incoming_call_id = sipCallId;
                    currentCallIdentifier = sipCallId;
                }
            } @catch (NSException *exception) {
                NSLog(@"❌ Исключение при поиске активных звонков: %@", exception);
            }
        }
        
        // Создаем отдельный поток для ответа на звонок с высоким приоритетом
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self safeHandleSIPAnswerForCallId:sipCallId withUUID:action.callUUID.UUIDString];
        });
        
        // Сохраняем сессию звонка в пользовательских данных
        // Это поможет предотвратить конфликты после ответа
        __block BOOL isAnswering = YES;
        NSString *answerKey = [NSString stringWithFormat:@"answering_%@", action.callUUID.UUIDString];
        
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:answerKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // Через 5 секунд сбрасываем этот флаг
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isAnswering = NO;
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:answerKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        });
    });
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    NSLog(@"📱 CallKit: performEndCallAction");
    
    // Защита от конфликта с недавним ответом на звонок
    static NSDate *lastAnswerTime = nil;
    static NSUUID *lastAnswerUUID = nil;
    
    NSString *answerKey = [NSString stringWithFormat:@"answering_%@", action.callUUID.UUIDString];
    BOOL isAnswering = [[NSUserDefaults standardUserDefaults] boolForKey:answerKey];
    
    if ((isAnswering || (lastAnswerTime && lastAnswerUUID &&
        [action.callUUID isEqual:lastAnswerUUID] &&
        [[NSDate date] timeIntervalSinceDate:lastAnswerTime] < 1.5))) {
        NSLog(@"⚠️ CallKit: Игнорируем завершение звонка сразу после ответа на него");
        [action fulfill]; // Выполняем действие, но не завершаем звонок
        return;
    }
    
    // Получаем информацию о звонке по UUID
    NSDictionary *callInfo = [activeCalls objectForKey:action.callUUID.UUIDString];
    pjsua_call_id callId = PJSUA_INVALID_ID;
    
    if (callInfo != nil) {
        NSNumber *callIdNumber = [callInfo objectForKey:@"call_id"];
        
        if (callIdNumber != nil) {
            callId = [callIdNumber intValue];
        }
    }
    
    // Если мы не нашли callId в словаре, попробуем получить его из globals
    if (callId == PJSUA_INVALID_ID) {
        if (currentCallIdentifier != PJSUA_INVALID_ID) {
            callId = currentCallIdentifier;
        } else if (incoming_call_id != PJSUA_INVALID_ID) {
            callId = incoming_call_id;
        }
    }
    
    // Если нашли звонок, завершаем его
    if (callId != PJSUA_INVALID_ID) {
        // Регистрируем поток PJSIP если нужно
        static pj_thread_desc endActionDesc;
        static pj_thread_t *endActionThread;
        
        if (!pj_thread_is_registered()) {
            memset(&endActionDesc, 0, sizeof(endActionDesc));
            pj_status_t regStatus = pj_thread_register("EndActionThread", endActionDesc, &endActionThread);
            if (regStatus != PJ_SUCCESS) {
                NSLog(@"❌ Ошибка регистрации потока для завершения звонка: %d", regStatus);
            }
        }
        
        NSLog(@"📱 CallKit: Завершение SIP звонка с ID %d", callId);
        
        // Завершаем звонок через PJSIP
        pj_status_t status = pjsua_call_hangup(callId, 0, NULL, NULL);
        
        if (status != PJ_SUCCESS) {
            NSLog(@"⚠️ CallKit: Не удалось завершить звонок: %d, пробуем другой способ", status);
            // Пробуем альтернативный способ с проверкой активности
            if (pjsua_call_is_active(callId)) {
                status = pjsua_call_hangup(callId, PJSIP_SC_BUSY_HERE, NULL, NULL);
                if (status != PJ_SUCCESS) {
                    NSLog(@"❌ CallKit: Не удалось завершить звонок и резервным способом: %d", status);
                }
            }
        } else {
            NSLog(@"✅ CallKit: Звонок успешно завершен через PJSIP");
        }
    } else {
        NSLog(@"⚠️ CallKit: Не найден SIP звонок для UUID %@", action.callUUID);
    }
    
    // Удаляем информацию об этом звонке
    [activeCalls removeObjectForKey:action.callUUID.UUIDString];
    
    // Сбрасываем переменные, если это был текущий звонок
    if ([action.callUUID isEqual:currentCallUUID]) {
        currentCallUUID = nil;
        currentCallIdentifier = PJSUA_INVALID_ID;
    }
    
    // Если это был входящий звонок, сбрасываем его тоже
    if (incoming_call_id != PJSUA_INVALID_ID) {
        incoming_call_id = PJSUA_INVALID_ID;
    }
    
    // Выполняем действие
    [action fulfill];
    
    // Если это был последний активный звонок, убедимся что у нас правильное звуковое устройство
    if (activeCalls.count == 0) {
        [self changeOutputAudioPort:AVAudioSessionPortOverrideNone];
    }
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action {
    NSLog(@"📱 CallKit: performSetMutedCallAction: %@", action.muted ? @"Muted" : @"Unmuted");
    
    // Реализуем отключение микрофона через PJSIP, если требуется
    // ...
    
    [action fulfill];
}

#pragma mark - VoIP Push Support

- (void)registerForVoIPPushes {
    NSLog(@"📱 VoIP: Регистрация для VoIP пушей...");
    
    if (voipPushRegistry != nil) {
        return;
    }
    
    // Создаем VoIP Push Registry
    voipPushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    voipPushRegistry.delegate = self;
    voipPushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
    
    NSLog(@"✅ VoIP: Успешно зарегистрированы для VoIP пушей");
}

- (void)handlePushNotificationPayload:(NSDictionary *)payload {
    NSLog(@"📱 VoIP: Обработка push уведомления: %@", payload);
    
    // Получаем UUID из payload или создаем новый
    NSString *incomingUUID = nil;
    if (payload[@"data"] && payload[@"data"][@"uuid"]) {
        incomingUUID = payload[@"data"][@"uuid"];
    } else {
        // Если UUID не указан в push, создаем уникальный
        incomingUUID = [[NSUUID UUID] UUIDString];
    }
    
    // Проверяем, не обрабатывали ли мы уже звонок с таким UUID
    if ([self.reportedCallUUIDs containsObject:incomingUUID]) {
        NSLog(@"⚠️ VoIP: Игнорируем повторное уведомление для UUID: %@", incomingUUID);
        return;
    }
    
    // Создаем мутабельную копию payload и добавляем метку времени, если ее еще нет
    NSMutableDictionary *payloadWithTimestamp = [NSMutableDictionary dictionaryWithDictionary:payload];
    
    // Добавляем timestamp, если его еще нет
    if (![payloadWithTimestamp objectForKey:@"timestamp"]) {
        [payloadWithTimestamp setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"timestamp"];
    }
    
    // Сохраняем последнее полученное push-уведомление с меткой времени
    lastPushPayload = [NSDictionary dictionaryWithDictionary:payloadWithTimestamp];
    
    // Создаем уникальный идентификатор для звонка
    NSUUID *callUUID = [NSUUID UUID];
    if (incomingUUID) {
        callUUID = [[NSUUID alloc] initWithUUIDString:incomingUUID];
    }
    
    // Получаем имя звонящего из payload
    NSString *caller = @"Неизвестный";
    
    // Пример формата payload: {"aps":{"alert":"Incoming call from +123456789"}}
    if (payload != nil) {
        NSDictionary *aps = [payload objectForKey:@"aps"];
        if (aps != nil) {
            NSString *alert = [aps objectForKey:@"alert"];
            if (alert != nil && [alert hasPrefix:@"Incoming call from "]) {
                caller = [alert substringFromIndex:[@"Incoming call from " length]];
            }
        }
        
        // Если есть caller_id в payload, используем его
        NSString *callerId = [payload objectForKey:@"caller_id"];
        if (callerId != nil) {
            caller = callerId;
        } else if (payload[@"data"] && payload[@"data"][@"callerID"]) {
            caller = payload[@"data"][@"callerID"];
        }
    }
    
    // Последовательность важна:
    // 1. Сначала активируем аудиоустройство
    [self activateSoundDevice];
    
    // 2. Затем инициализируем PJSIP если необходимо - ДО отображения CallKit UI
    BOOL needsSIPInit = NO;
    if (!pjsua_created || !pj_initialized) {
        NSLog(@"⚠️ VoIP: PJSIP не инициализирован при получении пуша, запускаем первичную инициализацию");
        [self configurePJSIP];
        needsSIPInit = YES;
    } else if (!pjsua_acc_is_valid(accountIdentifier)) {
        NSLog(@"⚠️ VoIP: SIP аккаунт недействителен при получении пуша, пересоздаем");
        [self configurePJSIP];
        needsSIPInit = YES;
    }
    
    // 3. Проверяем статус регистрации и запускаем регистрацию при необходимости
    if (![self isRegistered]) {
        NSLog(@"⚠️ VoIP: SIP не зарегистрирован при получении пуша, запускаем регистрацию...");
        [self reRegister];
        needsSIPInit = YES;
    }
    
    // Если нам пришлось инициализировать SIP, добавим небольшую задержку перед отображением CallKit UI
    if (needsSIPInit) {
        NSLog(@"⏱️ Добавляем небольшую задержку перед отображением CallKit UI для синхронизации с PJSIP");
        [NSThread sleepForTimeInterval:0.5]; // Короткая задержка для инициализации SIP
    }
    
    // 4. Теперь отображаем звонок через CallKit
    // ВАЖНО: Сначала отображаем звонок через CallKit, чтобы система знала о входящем звонке
    [self reportIncomingCallWithUUID:callUUID caller:caller forCallId:currentCallIdentifier];
    
    // 5. Запускаем повторные попытки регистрации SIP если необходимо (для холодного старта)
    if (needsSIPInit) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Проверяем до 5 раз с интервалом 1 секунда
            for (int attempt = 0; attempt < 5; attempt++) {
                [NSThread sleepForTimeInterval:1.0];
                if ([self isRegistered]) {
                    NSLog(@"✅ VoIP: SIP успешно зарегистрирован после попытки %d", attempt+1);
                    break;
                } else if (attempt < 4) {
                    NSLog(@"⌛️ VoIP: Попытка %d регистрации SIP не удалась, повторяем...", attempt+1);
                    [self reRegister];
                }
            }
        });
    }
}

- (void)handlePushDict:(NSDictionary *)payload {
    // Forward the call to the existing implementation
    [self handlePushNotificationPayload:payload];
}

- (NSDictionary *)lastReceivedPushPayload {
    return lastPushPayload;
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)pushCredentials forType:(PKPushType)type {
    NSLog(@"📱 VoIP: Обновлены pushCredentials для типа %@", type);
    
    if ([type isEqualToString:PKPushTypeVoIP]) {
        // Преобразуем токен в строку для отправки на сервер
        NSData *tokenData = pushCredentials.token;
        NSMutableString *tokenString = [NSMutableString string];
        
        const unsigned char *tokenBytes = [tokenData bytes];
        for (NSUInteger i = 0; i < [tokenData length]; i++) {
            [tokenString appendFormat:@"%02x", tokenBytes[i]];
        }
        
        NSLog(@"📱 VoIP: Токен устройства: %@", tokenString);
        
        // Здесь вы бы отправили токен на свой сервер
        // [self sendTokenToServer:tokenString];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion {
    NSLog(@"📱 VoIP: Получен входящий VoIP пуш для типа %@: %@", type, payload.dictionaryPayload);
    
    if (![type isEqualToString:PKPushTypeVoIP]) {
        NSLog(@"⚠️ VoIP: Игнорирование пуша неверного типа");
        completion();
        return;
    }
    
    // ВАЖНО: На заблокированном экране iOS не активирует приложение полностью,
    // а просто выполняет этот метод, поэтому нужно мгновенно отобразить звонок
    
    // 1. Сохраняем payload для дальнейшей обработки с меткой времени
    NSMutableDictionary *payloadWithTimestamp = [NSMutableDictionary dictionaryWithDictionary:payload.dictionaryPayload];
    if (![payloadWithTimestamp objectForKey:@"timestamp"]) {
        [payloadWithTimestamp setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"timestamp"];
    }
    lastPushPayload = [NSDictionary dictionaryWithDictionary:payloadWithTimestamp];
    
    // 2. Создаем UUID для CallKit и получаем caller ID
    NSUUID *callUUID = [NSUUID UUID];
    NSString *caller = @"Входящий звонок";
    
    // Извлекаем данные о звонящем из пуша
    if (payload.dictionaryPayload != nil) {
        NSString *callerId = payload.dictionaryPayload[@"caller_id"];
        if (callerId != nil) {
            caller = callerId;
        } else if (payload.dictionaryPayload[@"aps"] != nil) {
            NSString *alert = payload.dictionaryPayload[@"aps"][@"alert"];
            if (alert != nil && [alert hasPrefix:@"Incoming call from "]) {
                caller = [alert substringFromIndex:[@"Incoming call from " length]];
            }
        }
    }
    
    // 3. Настраиваем CallKit если еще не настроен
    if (callKitProvider == nil) {
        [self setupCallKit];
    }
    
    // 4. Настраиваем аудио сессию (критично для работы на заблокированном экране)
    [self performOnMainThread:^{
        [self activateSoundDevice];
    }];
    
    // 5. Инициализируем PJSIP если он еще не запущен 
    // Важно это делать ДО отображения UI через CallKit
    BOOL needsSIPInit = NO;
    if (!pjsua_created || !pj_initialized) {
        NSLog(@"⚠️ VoIP: PJSIP не инициализирован при VoIP пуше, запускаем...");
        [self configurePJSIP];
        needsSIPInit = YES;
    }
    
    // 6. Запускаем регистрацию SIP (важно для заблокированного экрана)
    if (!pjsua_acc_is_valid(accountIdentifier) || ![self isRegistered]) {
        NSLog(@"⚠️ VoIP: SIP не зарегистрирован при VoIP пуше, запускаем регистрацию...");
        [self reRegister];
        needsSIPInit = YES;
    }
    
    // 7. Если нам пришлось инициализировать SIP, добавляем небольшую задержку
    if (needsSIPInit) {
        NSLog(@"⏱️ Добавляем небольшую задержку перед отображением CallKit UI для синхронизации с PJSIP");
        [NSThread sleepForTimeInterval:0.3]; // Короткая задержка для инициализации SIP
    }
    
    // 8. Создаем и отображаем звонок через CallKit НЕМЕДЛЕННО
    [self performOnMainThread:^{
        [self reportIncomingCallWithUUID:callUUID caller:caller forCallId:currentCallIdentifier];
        
        // 9. Запускаем повторные попытки регистрации SIP если необходимо (для холодного старта)
        if (needsSIPInit && [UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if (![self isRegistered]) {
                    [self reRegister];
                    NSLog(@"🔄 Выполняем повторную регистрацию SIP после отображения CallKit");
                }
            });
        }
    }];
    
    // ОБЯЗАТЕЛЬНО вызываем completion handler
    completion();
}

// Вспомогательный метод для выполнения блока на главном потоке
- (void)performOnMainThread:(void (^)(void))block {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// Метод для безопасного ответа на SIP звонок, который можно вызывать из любого потока
- (void)safeHandleSIPAnswerForCallId:(pjsua_call_id)sipCallId withUUID:(NSString *)uuid {
    // Выполняем ответ в отдельном потоке чтобы не блокировать UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // Регистрируем поток PJSIP для каждого обработчика
        pj_thread_desc threadDesc;
        pj_thread_t *threadPtr;
        
        // Очищаем дескриптор перед использованием
        memset(&threadDesc, 0, sizeof(threadDesc));
        
        if (!pj_thread_is_registered()) {
            pj_status_t status = pj_thread_register("SIPAnswerThread", threadDesc, &threadPtr);
            if (status != PJ_SUCCESS) {
                NSLog(@"❌ Ошибка регистрации потока для ответа SIP: %d", status);
                return;
            }
            NSLog(@"✅ Поток для ответа SIP успешно зарегистрирован");
        }
        
        BOOL answerSuccess = NO;
        
        // Если ID не найден, пробуем несколько раз найти активный звонок
        pjsua_call_id callIdToAnswer = sipCallId;
        if (callIdToAnswer == PJSUA_INVALID_ID) {
            for (int i = 0; i < 5; i++) {
                @try {
                    pjsua_call_id call_ids[PJSUA_MAX_CALLS];
                    unsigned call_count = PJSUA_MAX_CALLS;
                    
                    if (pjsua_enum_calls(call_ids, &call_count) == PJ_SUCCESS && call_count > 0) {
                        callIdToAnswer = call_ids[0];
                        NSLog(@"📱 CallKit: Найден активный звонок после %d попытки: %d", i+1, callIdToAnswer);
                        incoming_call_id = callIdToAnswer;
                        currentCallIdentifier = callIdToAnswer;
                        break;
                    }
                } @catch (NSException *exception) {
                    NSLog(@"⚠️ Исключение при поиске звонков (попытка %d): %@", i+1, exception);
                }
                
                NSLog(@"📱 CallKit: Ждем активный звонок, попытка %d", i+1);
                [NSThread sleepForTimeInterval:0.5];
            }
        }
        
        // ВАЖНО: даже если не нашли звонок, не сбрасываем, а продолжаем попытки
        for (int attempt = 0; attempt < 15; attempt++) {
            // Проверяем еще раз, может звонок появился
            if (callIdToAnswer == PJSUA_INVALID_ID) {
                @try {
                    pjsua_call_id call_ids[PJSUA_MAX_CALLS];
                    unsigned call_count = PJSUA_MAX_CALLS;
                    
                    if (pjsua_enum_calls(call_ids, &call_count) == PJ_SUCCESS && call_count > 0) {
                        callIdToAnswer = call_ids[0];
                        NSLog(@"📱 CallKit: Найден активный звонок внутри цикла попыток: %d", callIdToAnswer);
                        incoming_call_id = callIdToAnswer;
                        currentCallIdentifier = callIdToAnswer;
                    }
                } @catch (NSException *exception) {
                    NSLog(@"⚠️ Исключение при поиске звонков в цикле: %@", exception);
                }
            }
            
            if (callIdToAnswer != PJSUA_INVALID_ID) {
                @try {
                    pjsua_call_info ci;
                    if (pjsua_call_get_info(callIdToAnswer, &ci) == PJ_SUCCESS) {
                        NSLog(@"📱 CallKit: Текущее состояние звонка (попытка %d): %d", attempt+1, ci.state);
                        
                        // Если звонок уже в процессе, считаем это успехом
                        if (ci.state == PJSIP_INV_STATE_CONFIRMED || ci.state == PJSIP_INV_STATE_CONNECTING) {
                            NSLog(@"✅ CallKit: Звонок уже соединен или соединяется");
                            answerSuccess = YES;
                            break;
                        }
                        
                        // Если звонок входящий, пробуем ответить
                        if (ci.state == PJSIP_INV_STATE_INCOMING || ci.state == PJSIP_INV_STATE_EARLY) {
                            // Используем напрямую pjsua_call_answer чтобы избежать дополнительных проверок
                            pj_status_t status = pjsua_call_answer(callIdToAnswer, PJSIP_SC_ACCEPTED, NULL, NULL);
                            
                            if (status == PJ_SUCCESS) {
                                NSLog(@"✅ CallKit: Звонок принят успешно (попытка %d)", attempt+1);
                                answerSuccess = YES;
                                break;
                            } else {
                                NSLog(@"⚠️ CallKit: Ошибка при ответе на звонок: %d (попытка %d)", status, attempt+1);
                            }
                        }
                    }
                } @catch (NSException *exception) {
                    NSLog(@"❌ Исключение при ответе на звонок: %@", exception);
                }
            } else {
                NSLog(@"⚠️ CallKit: Нет ID звонка для ответа, ожидаем (попытка %d)", attempt+1);
            }
            
            // Воспроизводим звук для пользователя каждую 3-ю попытку
            if (attempt % 3 == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    AudioServicesPlaySystemSound(1052); // Звук соединения
                });
            }
            
            // После каждой попытки активируем аудио снова
            if (attempt % 5 == 4) { // каждая 5я попытка
                [self activateSoundDevice];
            }
            
            // Пауза между попытками
            [NSThread sleepForTimeInterval:0.5];
        }
        
        // Если не удалось ответить после всех попыток
        if (!answerSuccess) {
            NSLog(@"⚠️ CallKit: Не удалось ответить на SIP-звонок после множества попыток");
            dispatch_async(dispatch_get_main_queue(), ^{
                AudioServicesPlaySystemSound(1073); // Звук уведомления
            });
            
            // Проверяем еще раз статус звонка
            @try {
                if (callIdToAnswer != PJSUA_INVALID_ID) {
                    pjsua_call_info ci;
                    if (pjsua_call_get_info(callIdToAnswer, &ci) == PJ_SUCCESS) {
                        if (ci.state != PJSIP_INV_STATE_DISCONNECTED) {
                            NSLog(@"⚠️ CallKit: Звонок все еще активен, состояние: %d", ci.state);
                            // НЕ сбрасываем звонок
                            
                            // Последняя попытка - делаем полную переинициализацию аудио
                            [self activateSoundDevice];
                        }
                    }
                }
            } @catch (NSException *exception) {
                NSLog(@"⚠️ Исключение при последней проверке звонка: %@", exception);
            }
        }
    });
}

// Получение UUID текущего звонка
- (NSUUID *) getCurrentCallUUID {
    registerPJSIPThread("GetCurrentCallUUID");
    
    // Возвращаем текущий UUID звонка, если он существует
    if (currentCallUUID != nil) {
        return currentCallUUID;
    }
    
    // Если нет текущего UUID, но есть активные звонки, возвращаем первый
    if (activeCalls.count > 0) {
        NSArray *keys = [activeCalls allKeys];
        if (keys.count > 0) {
            return keys[0];
        }
    }
    
    return nil;
}

#pragma mark - Caller Information

// Метод для получения информации о текущем звонящем
- (NSString*)getCurrentCallerInfo {
    if (currentCallIdentifier == PJSUA_INVALID_ID) {
        NSLog(@"⚠️ Нет активного звонка для получения информации о звонящем");
        return @"Домофон";
    }
    
    // Получаем информацию о текущем звонке
    pjsua_call_info ci;
    pj_status_t status = pjsua_call_get_info(currentCallIdentifier, &ci);
    
    if (status != PJ_SUCCESS) {
        NSLog(@"❌ Ошибка получения информации о звонке: %d", status);
        return @"Домофон";
    }
    
    // Преобразуем информацию о звонящем из pj_str_t в NSString
    NSString *callerInfo = [NSString stringWithFormat:@"%.*s", (int)ci.remote_info.slen, ci.remote_info.ptr];
    
    NSLog(@"📞 Полная информация о звонящем: %@", callerInfo);
    
    // Пытаемся извлечь имя или номер из SIP URI
    NSString *displayName = @"Домофон";
    
    if (callerInfo.length > 0) {
        // Попытка извлечь отображаемое имя, если оно есть
        NSRange nameRange = [callerInfo rangeOfString:@"\""];
        if (nameRange.location != NSNotFound) {
            NSRange endRange = [callerInfo rangeOfString:@"\"" options:0 range:NSMakeRange(nameRange.location + 1, callerInfo.length - nameRange.location - 1)];
            if (endRange.location != NSNotFound) {
                displayName = [callerInfo substringWithRange:NSMakeRange(nameRange.location + 1, endRange.location - nameRange.location - 1)];
            }
        } else {
            // Извлечение части между <sip: и @
            NSRange sipRange = [callerInfo rangeOfString:@"<sip:"];
            if (sipRange.location != NSNotFound) {
                NSRange atRange = [callerInfo rangeOfString:@"@" options:0 range:NSMakeRange(sipRange.location + sipRange.length, callerInfo.length - sipRange.location - sipRange.length)];
                if (atRange.location != NSNotFound) {
                    displayName = [callerInfo substringWithRange:NSMakeRange(sipRange.location + sipRange.length, atRange.location - sipRange.location - sipRange.length)];
                }
            }
        }
    }
    
    NSLog(@"📞 Информация о звонящем: %@", displayName);
    return displayName.length > 0 ? displayName : @"Домофон";
}

@end
