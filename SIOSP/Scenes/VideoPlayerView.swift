import SwiftUI
import UIKit
import MobileVLCKit

/// Hosts a VLC player inside SwiftUI, so the intercom's RTSP preview can sit
/// next to the call controls.
struct VideoPlayerView: UIViewRepresentable {
    let url: String
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        player.drawable = view

        if let url = URL(string: url) {
            let media = VLCMedia(url: url)

            // The intercom stream is watched, not listened to: its audio is
            // muted at every level VLC offers, because the call audio already
            // comes from SIP and two sources at once produce an echo.
            let options = [
                "network-caching": "3000",
                "live-caching": "3000",
                "rtsp-tcp": "1",
                "rtsp-frame-buffer-size": "1000000",
                "rtsp-timeout": "5",
                "rtsp-host": "127.0.0.1",   // fixed address for the connection
                "rtsp-port": "0",           // pick the port dynamically
                "audio-mute": "1",
                "no-audio": "1",
                "volume": "0",
                "gain": "0",
                "alsa-gain": "0"
            ]

            for (key, value) in options {
                media.addOption(":\(key)=\(value)")
            }

            player.audio?.volume = 0
            player.audio?.isMuted = true

            player.media = media
            player.play()

            print("✅ RTSP player started with audio muted")
        } else {
            print("❌ Could not build a URL for the video stream: \(url)")
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Nothing to refresh: the player is driven from outside this view.
    }
}

#if DEBUG
struct VideoPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Text("RTSP video player")
                .font(.headline)

            Text("VLC is not available in previews")
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(12)
                .padding()
        }
    }
}
#endif
