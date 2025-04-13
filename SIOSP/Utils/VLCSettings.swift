import Foundation
import MobileVLCKit

/// Вспомогательный класс для настроек VLC
class VLCSettings {
    static private var isInitialized = false
    
    /// Инициализирует глобальные настройки VLC
    static func setupGlobalSettings() {
        // Предотвращаем повторную инициализацию
        guard !isInitialized else { return }
        isInitialized = true
        
        // Аргументы командной строки VLC
        let args = [
            "--no-video-title-show",
            "--network-caching=3000",
            "--live-caching=3000",
            "--rtsp-tcp",
            "--ipv4-timeout=30",
            // Отключаем звук в RTSP по требованию
            "--audio-mute",
            "--no-audio",
            "--volume=0",
            "--gain=0",
            // Настройки для исправления ошибки с IP
            "--rtsp-host=127.0.0.1",
            "--verbose=3" // Для отладки
        ]
        
        // Создаем новую библиотеку VLC с нашими аргументами
        let vlcLibrary = VLCLibrary(options: args)
        
        // Устанавливаем уровень отладки
        vlcLibrary.debugLogging = true
        vlcLibrary.debugLoggingLevel = 3
        
        let version = vlcLibrary.version
        print("VLC version: \(version)")
    }
    
    /// Создает новый экземпляр VLCMediaPlayer с оптимальными настройками
    static func createOptimizedMediaPlayer() -> VLCMediaPlayer {
        // Сначала настраиваем глобальные параметры
        setupGlobalSettings()
        
        // Создаем плеер
        let player = VLCMediaPlayer()
        
        // Дополнительные настройки
        player.audio?.volume = 0    // Установка громкости в 0
        player.audio?.mute = true   // Принудительно включаем mute
        player.drawable = nil       // Сбрасываем drawable для предотвращения проблем
        
        return player
    }
} 