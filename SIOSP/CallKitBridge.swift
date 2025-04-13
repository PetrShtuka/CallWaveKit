import Foundation
import CallKit

// Класс-помощник для мониторинга состояния звонков CallKit
@objc class CallKitBridge: NSObject {
    @objc static let shared = CallKitBridge()
    
    private override init() {
        super.init()
        
        // Регистрируем для уведомлений от PJSIP при ответе через CallKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallAnsweredThroughCallKit),
            name: NSNotification.Name("PJSIP_CallKit_AnsweredCall"),
            object: nil
        )
        
        // Регистрируем для уведомлений от PJSIP при завершении через CallKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCallEndedThroughCallKit),
            name: NSNotification.Name("PJSIP_CallKit_EndedCall"),
            object: nil
        )
    }
    
    // Обработчик для ответа на звонок через CallKit
    @objc private func handleCallAnsweredThroughCallKit(_ notification: Notification) {
        // Отправляем уведомление для обновления UI
        NotificationCenter.default.post(
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil,
            userInfo: ["state": "answered"]
        )
    }
    
    // Обработчик для завершения звонка через CallKit
    @objc private func handleCallEndedThroughCallKit(_ notification: Notification) {
        // Отправляем уведомление для обновления UI
        NotificationCenter.default.post(
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil,
            userInfo: ["state": "ended"]
        )
    }
    
    // Метод для вызова при ответе на звонок из приложения
    @objc func callAnsweredFromApp() {
        NotificationCenter.default.post(
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil,
            userInfo: ["state": "answered"]
        )
    }
    
    // Метод для вызова при отклонении звонка из приложения
    @objc func callRejectedFromApp() {
        NotificationCenter.default.post(
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil,
            userInfo: ["state": "rejected"]
        )
    }
    
    // Метод для вызова при завершении звонка из приложения
    @objc func callEndedFromApp() {
        NotificationCenter.default.post(
            name: NSNotification.Name("PJSIPCallKitStateChanged"),
            object: nil,
            userInfo: ["state": "ended"]
        )
    }
} 