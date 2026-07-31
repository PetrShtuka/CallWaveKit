//
//  AppDelegate.swift
//  SIOSP
//
//  Created by Flavien SICARD on 1/19/19.
//  Copyright © 2019 sicardf. All rights reserved.
//

import UIKit
import AVFoundation
import UserNotifications
import PushKit
import BackgroundTasks

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var regCheckTimer: Timer?
    let calls = AppCallService()
    
    // Track registration state for UI updates
    var isSIPRegistered = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        
        // Создаем окно программно (обязательно для приложений без storyboard)
        self.window = UIWindow(frame: UIScreen.main.bounds)
        
        // Настройка аудиосессии осуществляется только в момент использования, не здесь
        // Это позволяет избежать проблем с мьютексами
        
        // ВАЖНО: Регистрируем для VoIP пушей как можно раньше, даже до настройки PJSIP
        // Это критично для работы на заблокированном экране
        DispatchQueue.main.async {
            self.calls.registerForVoIPPushes()
        }
        
        // Настройка фоновых режимов и уведомлений
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("⚠️ Notification authorization error: \(error)")
            }
        }
        
        // Настройка корневого контроллера на основе статуса логина
        setupRootViewController()
        
        // Запускаем SIP в фоновом потоке, чтобы не блокировать основной поток
        DispatchQueue.global(qos: .userInitiated).async {
            print("🚀 Инициализация PJSIP...")
            let status = self.calls.configurePJSIP()
            if status != 0 {
                print("❌ Error configuring PJSIP: \(status)")
            } else {
                print("✅ PJSIP configured successfully")
                
                // Даем паузу для завершения инициализации перед дальнейшими действиями
                Thread.sleep(forTimeInterval: 1.0)
                
                // Настраиваем CallKit один раз
                self.calls.setupCallKit()
                
                // Проверка статуса SIP-регистрации с достаточной задержкой после настройки
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.calls.isRegistered() {
                        print("✅ SIP успешно зарегистрирован после настройки")
                        self.isSIPRegistered = true
                    } else {
                        print("⚠️ SIP не зарегистрирован после настройки, перезапуск регистрации")
                        self.calls.reRegister()
                    }

                    self.regCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                        DispatchQueue.global(qos: .background).async {
                            self?.checkSIPRegistration()
                        }
                    }
                }
            }
        }
        
        // Регистрация фоновых задач для периодической поддержания SIP соединения
        if #available(iOS 16.0, *) {
            registerBackgroundTasks()
        }
        
        // Регистрируемся для удаленных уведомлений если доступно
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        
        // Регистрируем наблюдателей за уведомлениями входа и выхода
        NotificationCenter.default.addObserver(self, 
                                               selector: #selector(handleLoginNotification), 
                                               name: NSNotification.Name("LoginNotification"), 
                                               object: nil)
        
        NotificationCenter.default.addObserver(self, 
                                               selector: #selector(handleLogoutNotification), 
                                               name: NSNotification.Name("LogoutNotification"), 
                                               object: nil)
        
        // Setup notification observer for UI updates
        setupNotificationObservers()
        
        return true
    }

    // Новый метод для настройки корневого контроллера на основе статуса логина
    private func setupRootViewController() {
        let isLoggedIn = UserDefaults.standard.bool(forKey: "isLoggedIn")
        
        var initialViewController: UIViewController
        
        if isLoggedIn {
            // Пользователь уже вошел в систему - показываем основной экран SwiftUI
            let homeView = HomeView(calls: calls)
            initialViewController = HomeHostingController(rootView: homeView)
        } else {
            // Пользователь не вошел в систему - показываем SwiftUI экран логина
            let loginView = LoginView(calls: calls)
            initialViewController = LoginHostingController(rootView: loginView)
        }
        
        // Устанавливаем корневой контроллер
        window?.rootViewController = initialViewController
        window?.makeKeyAndVisible()
    }
    
    // Обработчик уведомления о входе в систему
    @objc private func handleLoginNotification() {
        DispatchQueue.main.async {
            // Переключаемся на главный экран SwiftUI
            let homeView = HomeView(calls: self.calls)
            let homeHostingController = HomeHostingController(rootView: homeView)
            
            // Анимированный переход
            let transition = CATransition()
            transition.duration = 0.5
            transition.type = .fade
            self.window?.layer.add(transition, forKey: kCATransition)
            
            self.window?.rootViewController = homeHostingController
        }
    }
    
    // Обработчик уведомления о выходе из системы
    @objc private func handleLogoutNotification() {
        DispatchQueue.main.async {
            // Переключаемся на экран логина SwiftUI
            let loginView = LoginView(calls: self.calls)
            let loginHostingController = LoginHostingController(rootView: loginView)
            
            // Анимированный переход
            let transition = CATransition()
            transition.duration = 0.5
            transition.type = .fade
            self.window?.layer.add(transition, forKey: kCATransition)
            
            self.window?.rootViewController = loginHostingController
        }
    }

    func checkSIPRegistration() {
        // Добавляем защиту от слишком частых проверок
        var lastCheckTime: TimeInterval = 0
        let currentTime = Date().timeIntervalSince1970
        
        // Не проверяем чаще чем раз в 10 секунд
        if currentTime - lastCheckTime < 10 {
            print("🕒 Пропускаем проверку SIP регистрации (слишком рано)")
            return
        }
        
        lastCheckTime = currentTime
        
        if self.calls.isRegistered() {
            print("✅ SIP регистрация активна")

            DispatchQueue.main.async {
                self.isSIPRegistered = true
            }
        } else {
            print("⚠️ SIP регистрация потеряна, восстанавливаем...")

            DispatchQueue.main.async {
                self.isSIPRegistered = false
            }
            self.calls.reRegister()
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
        
        // Запланировать фоновое обновление
        if #available(iOS 16.0, *) {
            scheduleAppRefresh()
        }
        
        // Проверка регистрации перед уходом в фон
        DispatchQueue.global(qos: .background).async {
            if !self.calls.isRegistered() {
                print("⚠️ SIP не зарегистрирован при уходе в фон, попытка регистрации")
                self.calls.reRegister()
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Приложение переходит из фона в активное состояние
        print("📱 Приложение возвращается на передний план")
        
        // Восстанавливаем SIP соединение с оптимизированной логикой
        restoreSIPConnection()
        
        // Сбрасываем счетчик неудачных попыток, если приложение было долго в фоне
        if let lastActiveTime = UserDefaults.standard.value(forKey: "lastActiveTime") as? TimeInterval {
            let currentTime = Date().timeIntervalSince1970
            // Если прошло более 5 минут с последней активности
            if currentTime - lastActiveTime > 300 {
                UserDefaults.standard.set(0, forKey: "sipRegFailureCount")
            }
        }
        
        // Сохраняем текущее время активности
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastActiveTime")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Проверка и восстановление SIP регистрации
        DispatchQueue.global(qos: .userInitiated).async {
            // Сначала проверяем, действительно ли нам нужна повторная регистрация
            let isCurrentlyRegistered = self.calls.isRegistered()
            
            // Обновляем UI статус на основе текущего состояния
            DispatchQueue.main.async {
                self.isSIPRegistered = isCurrentlyRegistered
            }
            
            // Если уже зарегистрированы, не пытаемся регистрироваться снова
            if isCurrentlyRegistered {
                print("✅ SIP уже зарегистрирован, пропускаем повторную регистрацию")
                
                // Проверяем наличие отложенных VoIP пушей
                if let lastPayload = self.calls.lastReceivedPushPayload() {
                    print("📱 Обработка отложенного VoIP пуша")
                    self.calls.handlePushNotificationPayload(lastPayload)
                }
                return
            }
            
            // Если не зарегистрированы, пробуем исправить ситуацию
            print("⚠️ SIP не зарегистрирован, попытка регистрации...")
            
            // Получаем сохранённые SIP параметры
            let domain = UserDefaults.standard.string(forKey: "domain")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = UserDefaults.standard.string(forKey: "username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password = UserDefaults.standard.string(forKey: "password") ?? ""
            
            // Проверяем и обрабатываем параметры соединения
            if !domain.isEmpty && !username.isEmpty && !password.isEmpty {
                print("📞 Восстановление SIP-регистрации с параметрами: \(username)@\(domain)")
                
                self.calls.reRegister()
            } else {
                // Если нет параметров, просто пытаемся переподключиться с текущими данными
                print("⚠️ Нет сохраненных SIP параметров, используем текущую конфигурацию")
                self.calls.reRegister()
            }
            
            // Обрабатываем отложенные VoIP уведомления при активации 
            if let nsDictPayload = self.calls.lastReceivedPushPayload() {
                // Используем вспомогательный метод для конвертации NSDictionary -> Swift Dictionary
                let swiftDict = self.calls.convertNSDictionaryToSwift(nsDictPayload as NSDictionary)
                
                // Проверяем, не старше ли пуш 60 секунд
                if let timestamp = swiftDict["timestamp"] as? TimeInterval,
                   Date().timeIntervalSince1970 - timestamp < 60 {
                    print("📱 Обработка отложенного VoIP уведомления при активации приложения")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.calls.handleSwiftPushNotification(swiftDict)
                    }
                }
            }
        }
        
        // Планируем фоновое обновление для поддержания регистрации
        if #available(iOS 16.0, *) {
            scheduleAppRefresh()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
        
        // Останавливаем таймер при завершении приложения
        regCheckTimer?.invalidate()
        
        // Запланировать фоновое обновление перед завершением
        if #available(iOS 16.0, *) {
            scheduleAppRefresh()
        }
        
        // Сохранить последнее состояние для восстановления при перезапуске
        UserDefaults.standard.synchronize()
    }

    // Обработчик фоновой задачи для поддержания SIP регистрации
    @available(iOS 16.0, *)
    func handleAppRefresh(task: BGAppRefreshTask) {
        // Создаем задачу отмены для фоновой операции
        let cancelWorkItem = DispatchWorkItem {
            task.setTaskCompleted(success: false)
        }
        
        // Устанавливаем срок выполнения - 25 секунд максимум
        task.expirationHandler = {
            cancelWorkItem.perform()
        }
        
        // Выполняем проверку и обновление SIP регистрации
        DispatchQueue.global(qos: .utility).async {
            if !self.calls.isRegistered() {
                print("⚠️ Background refresh: SIP не зарегистрирован, повторная регистрация")
                self.calls.reRegister()
            } else {
                print("✅ Background refresh: SIP регистрация активна")
            }
            
            // Запланировать следующее выполнение
            self.scheduleAppRefresh()
            
            // Отметить задачу как выполненную
            task.setTaskCompleted(success: true)
        }
    }

    // Планирование периодической фоновой задачи
    @available(iOS 16.0, *)
    func scheduleAppRefresh() {
        // Используем указанный идентификатор
        let request = BGAppRefreshTaskRequest(identifier: "com.petr.sip")
        // Выполнять каждые 15 минут минимум
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Background refresh task scheduled")
        } catch {
            print("❌ Could not schedule background refresh: \(error)")
        }
    }

    // Отдельный метод для регистрации фоновых задач
    @available(iOS 16.0, *)
    private func registerBackgroundTasks() {
        // Регистрируем с тем же идентификатором
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.petr.sip",
                                        using: nil) { [weak self] task in
            self?.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        
        print("✅ Зарегистрирована фоновая задача с идентификатором: com.petr.sip")
    }

    // MARK: - Настройка наблюдателей за уведомлениями
    
    private func setupNotificationObservers() {
        // Наблюдатель для обновления UI при изменении состояния звонка через CallKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(callKitCallStateDidChange),
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil
        )
        
        // Additional observers for CallKit integration with SwiftUI UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallKitAnswered),
            name: NSNotification.Name("AppCallAnswered"),
            object: nil
        )
        
        // Специальные наблюдатели для событий CallKit, которые могут приходить из PJSIP
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(callKitDidAcceptCall),
            name: NSNotification.Name("PJSIP_CallKit_AnsweredCall"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(callKitDidEndCall),
            name: NSNotification.Name("PJSIP_CallKit_EndedCall"),
            object: nil
        )
        
        // Обработчик запросов на проверку состояния CallKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkCallKitState),
            name: NSNotification.Name("CheckCallKitState"),
            object: nil
        )
    }
    
    @objc func handleSIPNetworkError(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else {
            return
        }
        
        let retryIn = userInfo["retryIn"] as? Int ?? 10
        
        // Show alert to user
        DispatchQueue.main.async {
            // Create and show a user notification
            let content = UNMutableNotificationContent()
            content.title = "Проблема с подключением"
            content.body = "\(message) Повторная попытка через \(retryIn) сек."
            content.sound = UNNotificationSound.default
            
            let request = UNNotificationRequest(identifier: "SIPNetworkError",
                                              content: content,
                                              trigger: nil)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Ошибка отображения уведомления: \(error)")
                }
            }
        }
    }
    
    @objc func handleSIPRegistrationSuccess(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isSIPRegistered = true
            
            // Отключаем частые проверки регистрации после успешной регистрации
            if let timer = self.regCheckTimer {
                timer.invalidate()
                // Устанавливаем новый таймер с более редкими проверками (раз в 5 минут)
                self.regCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                    DispatchQueue.global(qos: .background).async {
                        self?.checkSIPRegistration()
                    }
                }
            }
            
            print("✅ SIP регистрация успешна")
            
            // Сохраняем текущее время успешной регистрации
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSuccessfulRegistration")
            UserDefaults.standard.synchronize()
            
            // Показываем уведомление в случае, если было много неудачных попыток
            if let failureCount = UserDefaults.standard.value(forKey: "sipRegFailureCount") as? Int, failureCount > 3 {
                // Уведомление о восстановлении соединения
                let content = UNMutableNotificationContent()
                content.title = "Соединение восстановлено"
                content.body = "SIP регистрация успешно восстановлена"
                content.sound = UNNotificationSound.default
                
                let request = UNNotificationRequest(identifier: "SIPRegSuccess",
                                                   content: content,
                                                   trigger: nil)
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("❌ Ошибка отображения уведомления: \(error)")
                    }
                }
            }
            
            // Сбрасываем счетчик неудачных попыток
            UserDefaults.standard.set(0, forKey: "sipRegFailureCount")
        }
    }
    
    @objc func handleSIPRegistrationError(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else {
            return
        }
        
        DispatchQueue.main.async {
            self.isSIPRegistered = false
            
            // Увеличиваем счетчик неудачных попыток
            let failureCount = UserDefaults.standard.integer(forKey: "sipRegFailureCount") + 1
            UserDefaults.standard.set(failureCount, forKey: "sipRegFailureCount")
            
            // Формируем понятное сообщение
            var userFriendlyMessage = "Ошибка регистрации SIP"
            
            if message.contains("Connection refused") || message.contains("No route to host") {
                userFriendlyMessage = "Не удалось подключиться к SIP-серверу. Проверьте подключение к интернету."
            } else if message.contains("401") || message.contains("403") || message.contains("Auth") {
                userFriendlyMessage = "Неверные учетные данные SIP. Проверьте логин и пароль."
            } else if message.contains("timeout") || message.contains("timed out") {
                userFriendlyMessage = "Превышено время ожидания ответа от сервера SIP."
            } else {
                // Оставляем исходное сообщение, если не распознали специфическую ошибку
                userFriendlyMessage = "Проблема с SIP-соединением: \(message)"
            }
            
            print("❌ Ошибка регистрации SIP: \(message)")
            
            // Показываем уведомление только если это не первая неудачная попытка
            if failureCount > 1 {
                // Create and show a user notification
                let content = UNMutableNotificationContent()
                content.title = "Проблема с подключением"
                content.body = userFriendlyMessage
                content.sound = UNNotificationSound.default
                
                let request = UNNotificationRequest(identifier: "SIPRegistrationError",
                                                   content: content,
                                                   trigger: nil)
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("❌ Ошибка отображения уведомления: \(error)")
                    }
                }
            }
            
            // Если много последовательных ошибок, сделаем паузу перед следующими попытками
            if failureCount > 5 {
                print("⚠️ Слишком много неудачных попыток подключения. Делаем паузу.")
                // Установим флаг для пропуска нескольких проверок
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastFailedRegistration")
            }
        }
    }
    
    @objc func handleSIPConfigError(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else {
            return
        }
        
        DispatchQueue.main.async {
            print("⚠️ Ошибка конфигурации SIP: \(message)")
        }
    }
    
    @objc func handleSIPAccountError(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else {
            return
        }
        
        DispatchQueue.main.async {
            print("⚠️ Ошибка аккаунта SIP: \(message)")
        }
    }

    // MARK: - Методы для работы с SIP регистрацией
    
    /// Метод для восстановления SIP соединения с сохраненными параметрами
    func restoreSIPConnection() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Проверяем, прошло ли достаточно времени с последней неудачной попытки
            if let lastFailedTime = UserDefaults.standard.value(forKey: "lastFailedRegistration") as? TimeInterval {
                let currentTime = Date().timeIntervalSince1970
                // Если с момента последней неудачи прошло менее 60 секунд, пропускаем попытку
                if currentTime - lastFailedTime < 60 {
                    print("⏱️ Слишком мало времени прошло с последней неудачи, пропускаем попытку регистрации")
                    return
                }
            }
            
            // Если уже зарегистрированы, не пытаемся регистрироваться снова
            if self.calls.isRegistered() {
                print("✅ SIP уже зарегистрирован, пропускаем повторную регистрацию")
                return
            }
            
            print("🔄 Попытка восстановления SIP-соединения...")
            
            // Получаем сохранённые SIP параметры
            let domain = UserDefaults.standard.string(forKey: "domain")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = UserDefaults.standard.string(forKey: "username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let password = UserDefaults.standard.string(forKey: "password") ?? ""
            
            if !domain.isEmpty && !username.isEmpty && !password.isEmpty {
                print("📞 Восстановление SIP-регистрации с параметрами: \(username)@\(domain)")
                
                self.calls.reRegister()
            } else {
                print("⚠️ Нет сохраненных SIP параметров, используем имеющуюся конфигурацию")
                self.calls.reRegister()
            }
        }
    }

    // Handle when a call is answered from the app UI - we need to update CallKit
    @objc private func handleCallKitAnswered() {
        print("📱 App UI answered call - syncing with CallKit")
        // No need to do anything here as the app UI already handles the CallKit updates
    }

    // Метод для отправки уведомления об изменении состояния звонка через CallKit
    @objc func callKitCallStateDidChange(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            // Пересылаем уведомление для обновления UI
            NotificationCenter.default.post(
                name: NSNotification.Name("CallKitCallStateChanged"),
                object: nil,
                userInfo: userInfo
            )
            
            if let state = userInfo["state"] as? String {
                print("📱 Получено уведомление об изменении состояния звонка через CallKit: \(state)")
            }
        }
    }

    // Метод для отправки уведомления об изменении состояния звонка через CallKit
    @objc func callKitDidAcceptCall() {
        print("📱 AppDelegate: CallKit принял звонок - отправляем уведомление")
        // Отправляем уведомление для обновления UI
        NotificationCenter.default.post(
            name: NSNotification.Name("CallKitCallStateChanged"),
            object: nil,
            userInfo: ["state": "answered"]
        )
    }

    @objc func callKitDidEndCall() {
        print("📱 AppDelegate: CallKit завершил звонок - отправляем уведомление")
        // Отправляем уведомление для обновления UI
        NotificationCenter.default.post(
            name: NSNotification.Name("CallKitCallStateChanged"),
            object: nil,
            userInfo: ["state": "ended"]
        )
    }

    // Обработчик запроса на проверку текущего состояния CallKit
    @objc private func checkCallKitState(_ notification: Notification) {
        print("📱 AppDelegate: Проверка состояния CallKit по запросу")
        
        // Проверяем текущее состояние звонков через PJSIP
        // Используем метод getCurrentCallStatus() вместо hasSIPCall() и isCallConnected()
        let callStatus = self.calls.getCurrentCallStatus()
        
        if callStatus != 0 { // Если есть активный звонок (статус не 0)
            if callStatus == 1 { // Если звонок принят/соединен (статус 1)
                // Если звонок уже принят через CallKit, отправляем уведомление
                print("📱 AppDelegate: Обнаружен активный звонок в CallKit")
                NotificationCenter.default.post(
                    name: NSNotification.Name("CallKitCallStateChanged"),
                    object: nil,
                    userInfo: ["state": "answered"]
                )
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Всегда показываем уведомления, даже если приложение на переднем плане
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        // Обработка нажатия на уведомление
        let userInfo = response.notification.request.content.userInfo
        print("📱 Получено уведомление: \(userInfo)")
        
        // Если это уведомление о звонке, обрабатываем его как VoIP push
        if let aps = userInfo["aps"] as? [String: Any], 
           let alert = aps["alert"] as? String, 
           alert.hasPrefix("Incoming call from ") {
            // Используем Swift-дружественный метод
            self.calls.handleSwiftPushNotification(userInfo)
        }
        
        completionHandler()
    }
}

// MARK: - UIApplication Remote Notifications
extension AppDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Пересылаем токен в PJSIP для регистрации VoIP пушей
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 Получен токен для пуш-уведомлений: \(tokenString)")
        
        // Пересылаем токен в PJSIP если нужно
        // self.calls.setDeviceToken(tokenString)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📱 Received remote notification: \(userInfo)")
        
        // Если это уведомление о звонке, обрабатываем его как VoIP push
        if let aps = userInfo["aps"] as? [String: Any], 
           let alert = aps["alert"] as? String, 
           alert.hasPrefix("Incoming call from ") {
            // Используем Swift-дружественный метод
            self.calls.handleSwiftPushNotification(userInfo)
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }
}
