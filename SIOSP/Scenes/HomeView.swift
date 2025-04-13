import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

// Определение IncomingCallView внутри файла HomeView.swift
struct IncomingCallView: View {
    let callerInfo: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    
    var body: some View {
        ZStack {
            // Фоновый цвет
            Color(UIColor(red: 0.29, green: 0.478, blue: 0.604, alpha: 1.0))
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Spacer()
                
                // Информация о звонке
                VStack(spacing: 16) {
                    Text("Входящий звонок")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(callerInfo)
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(.bottom, 10)
                }
                
                Spacer()
                
                // Кнопки принятия/отклонения
                HStack(spacing: 50) {
                    // Кнопка отклонения
                    Button(action: onDecline) {
                        VStack {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding()
                                .background(Circle().fill(Color.red))
                                .frame(width: 60, height: 60)
                            
                            Text("Отклонить")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Кнопка принятия
                    Button(action: onAccept) {
                        VStack {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding()
                                .background(Circle().fill(Color.green))
                                .frame(width: 60, height: 60)
                            
                            Text("Ответить")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .padding()
        }
    }
}

// Определение ActiveCallView для отображения активного звонка
struct ActiveCallView: View {
    let callerInfo: String
    let callDuration: String
    let onEndCall: () -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            Text("Активный вызов с \(callerInfo)")
                .font(.headline)
                .multilineTextAlignment(.center)
            
            Text(callDuration)
                .font(.title2)
                .monospacedDigit()
                .padding(.top, 8)
            
            // Кнопка завершения вызова
            Button(action: onEndCall) {
                HStack {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 16))
                    Text("Завершить")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red))
                .foregroundColor(.white)
            }
            .padding(.top, 20)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
        .padding(.horizontal)
    }
}

// Определение UserInfoView для отображения информации о пользователе
struct UserInfoView: View {
    let username: String
    let domain: String
    
    var body: some View {
        VStack {
            Text("Добро пожаловать, \(username)!")
                .font(.headline)
                .padding(.top, 10)
            
            Text("Домен: \(domain)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

struct HomeView: View {
    @State private var isCallActive = false
    @State private var isIncomingCall = false
    @State private var callerInfo: String = "Домофон"
    @State private var callStartTime: Date?
    @State private var callDuration: String = "00:00"
    @State private var showLogoutAlert = false
    @State private var showSIPStatusAlert = false
    @State private var sipStatusMessage = ""
    @State private var showNetworkErrorAlert = false
    @State private var networkErrorMessage = ""
    @State private var isVideoPlayerVisible = true
    
    // RTSP-поток для домофона
    private let rtspUrl = "rtsp://92.39.70.62:60199/av0_0"
    // VLC плеер
    private let player = VLCMediaPlayer()
    
    // Таймер для обновления продолжительности звонка
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Основной контент
                VStack(spacing: 25) {
                    // Информация о пользователе
                    UserInfoView(
                        username: UserDefaults.standard.string(forKey: "username") ?? "пользователь",
                        domain: UserDefaults.standard.string(forKey: "domain") ?? ""
                    )
                    
                    // Видеоплеер - показываем только если не идет звонок
                    if isVideoPlayerVisible && !isCallActive {
                        videoPlayerContent
                    }
                    
                    Spacer()
                    
                    if isCallActive {
                        // Отображение информации об активном звонке
                        ActiveCallView(
                            callerInfo: callerInfo,
                            callDuration: callDuration,
                            onEndCall: endCall
                        )
                    } else if !isVideoPlayerVisible {
                        // Стандартная информация в неактивном состоянии без видеоплеера
                        VStack {
                            Text("Приложение готово принимать входящие звонки")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .padding()
                            
                            Text("Для звонка с домофона наберите 22")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 5)
                            
                            Text("Учетная запись: \(UserDefaults.standard.string(forKey: "username") ?? "412016022")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 20)
                        }
                    }
                    
                    Spacer()
                    
                    // Кнопка для переключения видимости видеоплеера
                    Button(action: {
                        withAnimation {
                            isVideoPlayerVisible.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: isVideoPlayerVisible ? "eye.slash" : "eye.fill")
                            Text(isVideoPlayerVisible ? "Скрыть видеопоток" : "Показать видеопоток")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                    }
                    .padding(.bottom, 20)
                }
                .blur(radius: isIncomingCall ? 3 : 0)
                
                // Слой для входящего звонка
                if isIncomingCall {
                    IncomingCallView(
                        callerInfo: callerInfo,
                        onAccept: acceptCall,
                        onDecline: declineCall
                    )
                    .transition(AnyTransition.opacity)
                    .zIndex(1)
                }
            }
            .navigationTitle("Мажордом Звонилка")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Выход") {
                        showLogoutAlert = true
                    }
                }
            }
            .onAppear {
                setupIncomingCallHandler()
                checkSIPRegistration()
                setupNetworkErrorObserver()
                setupVideoPlayer()
                checkCallStateOnStartup()
            }
            .onDisappear {
                cleanupVideoPlayer()
            }
            .alert("Состояние SIP", isPresented: $showSIPStatusAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(sipStatusMessage)
            }
            .alert("Ошибка сети", isPresented: $showNetworkErrorAlert) {
                Button("Повторить", role: .cancel) {
                    checkSIPRegistration()
                }
            } message: {
                Text(networkErrorMessage)
            }
            .alert("Выход", isPresented: $showLogoutAlert) {
                Button("Отмена", role: .cancel) { }
                Button("Выйти", role: .destructive) {
                    logout()
                }
            } message: {
                Text("Вы уверены, что хотите выйти?")
            }
            .onReceive(timer) { _ in
                updateCallDuration()
            }
        }
    }
    
    // MARK: - Вспомогательные представления
    
    private var videoPlayerContent: some View {
        VStack {
            VideoPlayerView(url: rtspUrl, player: player)
                .frame(height: 240)
                .cornerRadius(12)
                .padding(.horizontal)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .padding(.vertical, 10)
            
            // Кнопка для обновления видеопотока
            Button(action: refreshVideoStream) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("Обновить поток")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Вспомогательные функции
    
    private func setupVideoPlayer() {
        // Звук RTSP всегда выключен
        player.audio?.volume = 0
        player.audio?.isMuted = true
        
        // Запускаем плеер
        refreshVideoStream()
    }
    
    private func cleanupVideoPlayer() {
        // Останавливаем плеер при закрытии вида
        if player.isPlaying {
            player.stop()
        }
    }
    
    private func refreshVideoStream() {
        if player.isPlaying {
            player.stop()
        } 
        
        // Создаем и запускаем новый поток
        if let url = URL(string: rtspUrl) {
            let media = VLCMedia(url: url)
            
            // Применяем параметры RTSP с отключенным звуком
            let options = [
                "network-caching": "3000",
                "live-caching": "3000",
                "rtsp-tcp": "1", 
                "rtsp-frame-buffer-size": "1000000",
                "rtsp-timeout": "5",
                "audio-mute": "1",
                "no-audio": "1",
                "volume": "0"
            ]
            
            for (key, value) in options {
                media.addOption(":\(key)=\(value)")
            }
            
            player.media = media
            player.play()
            
            print("✅ RTSP плеер запущен (поток: \(rtspUrl))")
        } else {
            print("❌ Ошибка: не удалось создать URL для видеопотока")
        }
    }
    
    // MARK: - Функции
    
    private func setupIncomingCallHandler() {
        // Настраиваем обработчик входящего звонка
        PJSIPIntegration.sharedInstance().configureIncomingCall {
            print("⚡️ Обработка входящего звонка в SwiftUI")
            
            // Получаем информацию о звонящем
            DispatchQueue.main.async {
                let caller = PJSIPIntegration.sharedInstance().getCurrentCallerInfo() as String? ?? "Домофон"
                callerInfo = caller.isEmpty ? "Домофон" : caller
                
                // Проверяем, не был ли звонок уже принят через CallKit
                let callStatus = PJSIPIntegration.sharedInstance().getCurrentCallStatus()
                if callStatus == 1 { // 1 = звонок принят/активен
                    print("⚡️ Звонок уже принят через CallKit, обновляем UI напрямую")
                    withAnimation {
                        isIncomingCall = false
                        isCallActive = true
                        callStartTime = Date()
                    }
                } else {
                    // Показываем входящий звонок
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isIncomingCall = true
                    }
                    
                    // Запускаем таймер проверки, не ответили ли на звонок через CallKit
                    startCallKitStateCheckTimer()
                }
            }
        }
        
        // Настраиваем обработчик завершения звонка
        PJSIPIntegration.sharedInstance().configureEndCall {
            DispatchQueue.main.async {
                // Явно завершаем звонок в CallKit, если он активен
                if let callUUID = PJSIPIntegration.sharedInstance().getCurrentCallUUID() {
                    print("📱 Явное завершение CallKit сессии для UUID: \(callUUID)")
                    PJSIPIntegration.sharedInstance().endCall(with: callUUID)
                }
                
                withAnimation {
                    isCallActive = false
                    isIncomingCall = false
                }
            }
        }
        
        // Особый обработчик для ответа на звонок через CallKit
        // Этот обработчик критичен для синхронизации UI при ответе через системный интерфейс
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CXProviderDidActivateAudioSession"), 
            object: nil,
            queue: .main
        ) { _ in
            print("📱 CallKit активировал аудио сессию - это означает ответ на звонок")
            withAnimation {
                self.isIncomingCall = false
                self.isCallActive = true
                self.callStartTime = Date()
            }
        }
        
        // Добавляем наблюдатель за ответом на звонок через CallKit
        // Это необходимо, чтобы синхронизировать UI приложения с состоянием CallKit
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CallKitCallStateChanged"),
            object: nil,
            queue: .main
        ) { notification in
            guard let state = notification.userInfo?["state"] as? String else { return }
            
            print("📱 Получено уведомление о событии CallKit: \(state)")
            
            switch state {
            case "answered":
                print("📱 Звонок принят через CallKit - обновляем UI")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = true
                    self.callStartTime = Date()
                }
            case "ended":
                print("📱 Звонок завершен через CallKit - обновляем UI")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = false
                }
            case "rejected":
                print("📱 Звонок отклонен через CallKit - обновляем UI")
                withAnimation {
                    self.isIncomingCall = false
                }
            default:
                break
            }
        }
    }
    
    // Таймер для проверки состояния звонка через CallKit
    private func startCallKitStateCheckTimer() {
        // Проверяем каждые 0.5 секунд, не ответили ли на звонок через CallKit
        var checkCount = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            // Проверяем, принят ли звонок через CallKit
            let callStatus = PJSIPIntegration.sharedInstance().getCurrentCallStatus()
            if isIncomingCall && callStatus == 1 { // 1 = звонок принят/активен
                print("⚡️ Обнаружено, что звонок принят через CallKit")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = true
                    self.callStartTime = Date()
                }
                timer.invalidate()
            }
            
            // Проверяем, завершен ли звонок
            if callStatus == 0 && (isIncomingCall || isCallActive) { // 0 = нет активных звонков
                print("⚡️ Обнаружено, что звонок завершен через CallKit")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = false
                }
                timer.invalidate()
            }
            
            // Ограничиваем количество проверок (примерно 10 секунд)
            checkCount += 1
            if checkCount > 20 {
                print("⏱️ Остановка таймера проверки CallKit после 20 попыток")
                timer.invalidate()
            }
        }
        
        // Убеждаемся, что таймер добавлен в основной цикл выполнения
        RunLoop.current.add(timer, forMode: .common)
    }
    
    private func checkSIPRegistration() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if PJSIPIntegration.sharedInstance().isRegistered() {
                print("✅ SIP registration active")
                sipStatusMessage = "Успешно зарегистрирован на SIP сервере"
            } else {
                print("⚠️ SIP registration not active, reconnecting...")
                PJSIPIntegration.sharedInstance().reRegister()
                sipStatusMessage = "Регистрация не активна. Подключение..."
            }
            showSIPStatusAlert = true
        }
    }
    
    private func acceptCall() {
        print("⚡️ Звонок принят из пользовательского интерфейса")
        
        // Активация аудио должна происходить ДО ответа на звонок
        if PJSIPIntegration.sharedInstance().activateSoundDevice() {
            print("✅ Аудио активировано для звонка")
            
            // Сначала отвечаем через CallKit, если есть UUID звонка
            if let callUUID = PJSIPIntegration.sharedInstance().getCurrentCallUUID() {
                print("📱 Отвечаем через CallKit для UUID: \(callUUID)")
                
                // Вызываем метод для автоматического ответа через CallKit интерфейс
                // Это имитирует ответ на звонок через системный UI и закрывает его
                let controller = CXCallController()
                let answerAction = CXAnswerCallAction(call: callUUID)
                let transaction = CXTransaction(action: answerAction)
                
                controller.request(transaction) { error in
                    if let error = error {
                        print("❌ Ошибка ответа через CallKit: \(error)")
                    } else {
                        print("✅ Успешно ответили через CallKit")
                        
                        // Обновляем UI после успешного ответа через CallKit
                        DispatchQueue.main.async {
                            withAnimation {
                                self.isIncomingCall = false
                                self.isCallActive = true
                                self.callStartTime = Date()
                            }
                        }
                    }
                }
                
                // Уведомляем CallKit о соединении
                print("📱 Уведомление CallKit о соединении для UUID: \(callUUID)")
                PJSIPIntegration.sharedInstance().connectedCall(with: callUUID)
            }
            
            // Затем принимаем SIP-звонок напрямую через PJSIP
            if PJSIPIntegration.sharedInstance().acceptCall() {
                print("✅ Звонок успешно принят через PJSIP")
                
                // Обновляем UI для отображения активного звонка
                withAnimation {
                    isIncomingCall = false
                    isCallActive = true
                    callStartTime = Date()
                }
                
                // Оповещаем о принятии звонка через наш мост для синхронизации состояний
                CallKitBridge.shared.callAnsweredFromApp()
            } else {
                print("❌ Ошибка при принятии звонка через PJSIP")
                withAnimation {
                    isIncomingCall = false
                }
            }
        } else {
            print("❌ Ошибка активации аудио для звонка")
            withAnimation {
                isIncomingCall = false
            }
        }
    }
    
    private func declineCall() {
        print("⚡️ Звонок отклонен")
        
        // Сначала уведомляем CallKit об отклонении, если есть UUID звонка
        if let callUUID = PJSIPIntegration.sharedInstance().getCurrentCallUUID() {
            print("📱 Уведомление CallKit об отклонении для UUID: \(callUUID)")
            
            // Завершаем звонок через CallKit
            let controller = CXCallController()
            let endAction = CXEndCallAction(call: callUUID)
            let transaction = CXTransaction(action: endAction)
            
            controller.request(transaction) { error in
                if let error = error {
                    print("❌ Ошибка завершения звонка через CallKit: \(error)")
                } else {
                    print("✅ Успешно завершили звонок через CallKit")
                }
            }
            
            // Дополнительно вызываем метод PJSIP для завершения CallKit сессии
            PJSIPIntegration.sharedInstance().endCall(with: callUUID)
        }
        
        // Отклоняем звонок через PJSIP
        if PJSIPIntegration.sharedInstance().declineCall() {
            print("✅ Звонок успешно отклонен через PJSIP")
        } else {
            print("❌ Ошибка при отклонении звонка через PJSIP")
        }
        
        // Отключаем аудио
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ Аудио сессия деактивирована после отклонения звонка")
        } catch {
            print("❌ Ошибка деактивации аудио сессии: \(error)")
        }
        
        withAnimation {
            isIncomingCall = false
        }
        
        // Оповещаем о отклонении звонка через наш мост для синхронизации состояний
        CallKitBridge.shared.callRejectedFromApp()
    }
    
    private func endCall() {
        // Сначала завершаем CallKit сессию, если она существует
        if let callUUID = PJSIPIntegration.sharedInstance().getCurrentCallUUID() {
            print("📱 Завершение CallKit сессии из UI для UUID: \(callUUID)")
            
            // Завершаем звонок через CallKit
            let controller = CXCallController()
            let endAction = CXEndCallAction(call: callUUID)
            let transaction = CXTransaction(action: endAction)
            
            controller.request(transaction) { error in
                if let error = error {
                    print("❌ Ошибка завершения звонка через CallKit: \(error)")
                } else {
                    print("✅ Успешно завершили звонок через CallKit")
                }
            }
            
            // Также вызываем метод PJSIP для завершения CallKit сессии
            PJSIPIntegration.sharedInstance().endCall(with: callUUID)
        }
        
        // Затем завершаем SIP-звонок напрямую через PJSIP
        if PJSIPIntegration.sharedInstance().stopCall() {
            print("✅ Звонок успешно завершен через PJSIP")
        } else {
            print("❌ Ошибка при завершении звонка через PJSIP")
        }
        
        // Отключаем аудио
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ Аудио сессия деактивирована")
        } catch {
            print("❌ Ошибка деактивации аудио сессии: \(error)")
        }
        
        withAnimation {
            isCallActive = false
        }
        
        // Оповещаем о завершении звонка через наш мост для синхронизации состояний
        CallKitBridge.shared.callEndedFromApp()
    }
    
    private func logout() {
        // Сбрасываем флаг входа в систему
        UserDefaults.standard.set(false, forKey: "isLoggedIn")
        UserDefaults.standard.removeObject(forKey: "domain")
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.removeObject(forKey: "password")
        
        // Подготавливаем уведомление для AppDelegate, чтобы обновить root view controller
        NotificationCenter.default.post(name: NSNotification.Name("LogoutNotification"), object: nil)
    }
    
    private func setupNetworkErrorObserver() {
        // Регистрируем обработчик уведомлений об ошибках сети
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SIPNetworkError"),
            object: nil,
            queue: .main
        ) { notification in
            if let message = notification.userInfo?["message"] as? String {
                self.networkErrorMessage = message
                self.showNetworkErrorAlert = true
            }
        }
    }
    
    private func updateCallDuration() {
        if isCallActive, let startTime = callStartTime {
            let duration = Int(Date().timeIntervalSince(startTime))
            let minutes = duration / 60
            let seconds = duration % 60
            callDuration = String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    // MARK: - Отслеживание состояния активного звонка
    
    // Запускается на старте для проверки текущего состояния звонков
    private func checkCallStateOnStartup() {
        // Отложенная проверка, чтобы UI успел загрузиться
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Проверяем, есть ли уже активный звонок (например, если приложение было перезапущено во время звонка)
            let callStatus = PJSIPIntegration.sharedInstance().getCurrentCallStatus()
            if callStatus != 0 { // Если есть какой-то звонок (статус не 0)
                print("⚡️ Обнаружен активный звонок при запуске - обновляем UI")
                
                // Получаем информацию о звонящем
                let caller = PJSIPIntegration.sharedInstance().getCurrentCallerInfo() as String? ?? "Домофон"
                callerInfo = caller.isEmpty ? "Домофон" : caller
                
                // Проверяем состояние звонка
                if callStatus == 1 { // 1 = звонок принят/активен
                    // Звонок уже был принят - показываем активный звонок
                    withAnimation {
                        isIncomingCall = false
                        isCallActive = true
                        callStartTime = Date() // Приблизительное время
                    }
                } else {
                    // Звонок еще не принят - показываем входящий звонок
                    withAnimation {
                        isIncomingCall = true
                        isCallActive = false
                    }
                }
            }
            
            // Отправляем запрос на проверку состояния звонка в CallKit
            // Это поможет синхронизировать состояние, если звонок ответили через CallKit
            NotificationCenter.default.post(name: NSNotification.Name("CheckCallKitState"), object: nil)
        }
    }
}

// MARK: - HomeHostingController
class HomeHostingController: UIHostingController<HomeView> {
    override init(rootView: HomeView) {
        super.init(rootView: rootView)
    }
    
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
