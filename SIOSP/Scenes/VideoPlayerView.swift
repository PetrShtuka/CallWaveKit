import SwiftUI
import UIKit
import MobileVLCKit

/// UIViewRepresentable для отображения VLC плеера в SwiftUI
struct VideoPlayerView: UIViewRepresentable {
    let url: String
    let player: VLCMediaPlayer
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
        // Устанавливаем view как отображение для плеера
        player.drawable = view
        
        // Создаем медиа с URL
        if let url = URL(string: url) {
            let media = VLCMedia(url: url)
            
            // Применяем параметры RTSP с отключенным звуком
            let options = [
                "network-caching": "3000",
                "live-caching": "3000",
                "rtsp-tcp": "1",
                "rtsp-frame-buffer-size": "1000000",
                "rtsp-timeout": "5",
                "rtsp-host": "127.0.0.1",  // Фиксированный IP-адрес для подключения
                "rtsp-port": "0",           // Использовать динамический порт
                "audio-mute": "1",          // Принудительно отключаем звук
                "no-audio": "1",            // Полностью отключаем аудио поток
                "volume": "0",              // Устанавливаем громкость на 0
                "gain": "0",                // Устанавливаем усиление на 0
                "alsa-gain": "0"            // Усиление ALSA на 0
            ]
            
            for (key, value) in options {
                media.addOption(":\(key)=\(value)")
            }
            
            // Принудительно отключаем звук для RTSP
            player.audio?.volume = 0
            player.audio?.isMuted = true
            
            // Устанавливаем медиа для плеера
            player.media = media
            
            // Запускаем воспроизведение
            player.play()
            
            print("✅ RTSP плеер инициализирован с отключенным звуком")
        } else {
            print("❌ Ошибка: не удалось создать URL для видеопотока")
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Обновление не требуется, плеер контролируется внешне
    }
}

#if DEBUG
struct VideoPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Text("RTSP видеоплеер")
                .font(.headline)
            
            Text("VLC недоступен в превью")
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(12)
                .padding()
        }
    }
}
#endif 
