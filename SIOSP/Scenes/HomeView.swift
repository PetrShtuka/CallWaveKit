import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

/// Full-screen prompt shown while the intercom is ringing.
struct IncomingCallView: View {
    let callerInfo: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    
    var body: some View {
        ZStack {
            // Background
            Color(UIColor(red: 0.29, green: 0.478, blue: 0.604, alpha: 1.0))
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Spacer()
                
                // Who is calling
                VStack(spacing: 16) {
                    Text("Incoming call")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(callerInfo)
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(.bottom, 10)
                }
                
                Spacer()
                
                // Decline / answer
                HStack(spacing: 50) {
                    // Decline
                    Button(action: onDecline) {
                        VStack {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding()
                                .background(Circle().fill(Color.red))
                                .frame(width: 60, height: 60)
                            
                            Text("Decline")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Answer
                    Button(action: onAccept) {
                        VStack {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .padding()
                                .background(Circle().fill(Color.green))
                                .frame(width: 60, height: 60)
                            
                            Text("Answer")
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

/// Shown once the call is connected.
struct ActiveCallView: View {
    let callerInfo: String
    let callDuration: String
    let onEndCall: () -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            Text("In a call with \(callerInfo)")
                .font(.headline)
                .multilineTextAlignment(.center)
            
            Text(callDuration)
                .font(.title2)
                .monospacedDigit()
                .padding(.top, 8)
            
            // Hang up
            Button(action: onEndCall) {
                HStack {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 16))
                    Text("End")
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

/// The signed-in SIP account.
struct UserInfoView: View {
    let username: String
    let domain: String
    
    var body: some View {
        VStack {
            Text("Welcome, \(username)!")
                .font(.headline)
                .padding(.top, 10)
            
            Text("Domain: \(domain)")
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
    let calls: AppCallService

    @State private var isCallActive = false
    @State private var isIncomingCall = false
    @State private var callerInfo: String = "Intercom"
    @State private var callStartTime: Date?
    @State private var callDuration: String = "00:00"
    @State private var showLogoutAlert = false
    @State private var showSIPStatusAlert = false
    @State private var sipStatusMessage = ""
    @State private var showNetworkErrorAlert = false
    @State private var networkErrorMessage = ""
    @State private var isVideoPlayerVisible = true
    
    // The intercom's RTSP stream.
    private let rtspUrl = "rtsp://92.39.70.62:60199/av0_0"
    // VLC player.
    private let player = VLCMediaPlayer()
    
    // Drives the call-duration label.
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Main content
                VStack(spacing: 25) {
                    // Account summary
                    UserInfoView(
                        username: UserDefaults.standard.string(forKey: "username") ?? "user",
                        domain: UserDefaults.standard.string(forKey: "domain") ?? ""
                    )
                    
                    // The video stays visible during a call as well, so the
                    // user can see who is at the door while talking.
                    if isVideoPlayerVisible {
                        videoPlayerContent
                    }
                    
                    Spacer()
                    
                    if isCallActive {
                        // Connected call
                        ActiveCallView(
                            callerInfo: callerInfo,
                            callDuration: callDuration,
                            onEndCall: endCall
                        )
                    } else if !isVideoPlayerVisible {
                        // Idle, with the video hidden
                        VStack {
                            Text("Ready to receive incoming calls")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .padding()
                            
                            Text("Dial 22 to call from the intercom")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 5)
                            
                            Text("Account: \(UserDefaults.standard.string(forKey: "username") ?? "412016022")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 20)
                        }
                    }
                    
                    Spacer()
                    
                    // Show or hide the video stream
                    Button(action: {
                        withAnimation {
                            isVideoPlayerVisible.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: isVideoPlayerVisible ? "eye.slash" : "eye.fill")
                            Text(isVideoPlayerVisible ? "Hide video" : "Show video")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                    }
                    .padding(.bottom, 20)
                }
                .blur(radius: isIncomingCall ? 3 : 0)
                
                // Incoming-call overlay
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
            .navigationTitle("Majordomo Dialer")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sign out") {
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
            .alert("SIP status", isPresented: $showSIPStatusAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(sipStatusMessage)
            }
            .alert("Network error", isPresented: $showNetworkErrorAlert) {
                Button("Retry", role: .cancel) {
                    checkSIPRegistration()
                }
            } message: {
                Text(networkErrorMessage)
            }
            .alert("Sign out", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Sign out", role: .destructive) {
                    logout()
                }
            } message: {
                Text("Are you sure you want to sign out?")
            }
            .onReceive(timer) { _ in
                updateCallDuration()
            }
        }
    }
    
    // MARK: - Subviews
    
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
            
            // Restart the stream
            Button(action: refreshVideoStream) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("Reload stream")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Video
    
    private func setupVideoPlayer() {
        // The RTSP audio is always off: the call audio comes from SIP.
        player.audio?.volume = 0
        player.audio?.isMuted = true
        
        // Start playing.
        refreshVideoStream()
    }
    
    private func cleanupVideoPlayer() {
        // Stop the player when the view goes away.
        if player.isPlaying {
            player.stop()
        }
    }
    
    private func refreshVideoStream() {
        if player.isPlaying {
            player.stop()
        } 
        
        // Build a fresh stream and start it.
        if let url = URL(string: rtspUrl) {
            let media = VLCMedia(url: url)
            
            // RTSP options, with the audio muted.
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
            
            print("✅ RTSP player started (stream: \(rtspUrl))")
        } else {
            print("❌ Could not build a URL for the video stream")
        }
    }
    
    // MARK: - Calls
    
    private func setupIncomingCallHandler() {
        // Incoming call.
        self.calls.configureIncomingCall {
            print("⚡️ Handling an incoming call in SwiftUI")
            
            // Who is calling.
            DispatchQueue.main.async {
                let caller = self.calls.getCurrentCallerInfo() as String? ?? "Intercom"
                callerInfo = caller.isEmpty ? "Intercom" : caller
                
                // The user may already have answered from the CallKit screen.
                let callStatus = self.calls.getCurrentCallStatus()
                if callStatus == 1 { // 1 = answered or active
                    print("⚡️ Already answered through CallKit, updating the UI directly")
                    withAnimation {
                        isIncomingCall = false
                        isCallActive = true
                        callStartTime = Date()
                    }
                } else {
                    // Show the incoming call.
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isIncomingCall = true
                    }
                    
                    // Poll in case the answer comes from the CallKit screen.
                    startCallKitStateCheckTimer()
                }
            }
        }
        
        // Call ended.
        self.calls.configureEndCall {
            DispatchQueue.main.async {
                withAnimation {
                    isCallActive = false
                    isIncomingCall = false
                }
            }
        }

        self.calls.configureStartCall {
            DispatchQueue.main.async {
                withAnimation {
                    isIncomingCall = false
                    isCallActive = true
                    callStartTime = Date()
                }
            }
        }
        
        // Answering from the system call screen only shows up as an audio
        // session activation, and the UI has to follow it.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CXProviderDidActivateAudioSession"), 
            object: nil,
            queue: .main
        ) { _ in
            print("📱 CallKit activated the audio session, so the call was answered")
            withAnimation {
                self.isIncomingCall = false
                self.isCallActive = true
                self.callStartTime = Date()
            }
        }
        
        // Keeps the application UI in step with the CallKit call state.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CallKitCallStateChanged"),
            object: nil,
            queue: .main
        ) { notification in
            guard let state = notification.userInfo?["state"] as? String else { return }
            
            print("📱 CallKit event: \(state)")
            
            switch state {
            case "answered":
                print("📱 Answered through CallKit, updating the UI")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = true
                    self.callStartTime = Date()
                }
            case "ended":
                print("📱 Ended through CallKit, updating the UI")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = false
                }
            case "rejected":
                print("📱 Declined through CallKit, updating the UI")
                withAnimation {
                    self.isIncomingCall = false
                }
            default:
                break
            }
        }
    }
    
    /// Polls the call state, because answering from the CallKit screen does
    /// not go through this view.
    private func startCallKitStateCheckTimer() {
        // Check twice a second.
        var checkCount = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            // Answered?
            let callStatus = self.calls.getCurrentCallStatus()
            if isIncomingCall && callStatus == 1 { // 1 = answered or active
                print("⚡️ The call was answered through CallKit")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = true
                    self.callStartTime = Date()
                }
                timer.invalidate()
            }
            
            // Ended?
            if callStatus == 0 && (isIncomingCall || isCallActive) { // 0 = no active call
                print("⚡️ The call was ended through CallKit")
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = false
                }
                timer.invalidate()
            }
            
            // Give up after roughly ten seconds.
            checkCount += 1
            if checkCount > 20 {
                print("⏱️ Stopping the CallKit poll after 20 attempts")
                timer.invalidate()
            }
        }
        
        // Keep firing while the user is scrolling.
        RunLoop.current.add(timer, forMode: .common)
    }
    
    private func checkSIPRegistration() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.calls.isRegistered() {
                print("✅ SIP registration active")
                sipStatusMessage = "Registered with the SIP server"
            } else {
                print("⚠️ SIP registration not active, reconnecting...")
                self.calls.reRegister()
                sipStatusMessage = "Not registered. Connecting…"
            }
            showSIPStatusAlert = true
        }
    }
    
    private func acceptCall() {
        print("⚡️ Call answered from the application UI")

        self.calls.answer { error in
            if let error {
                print("❌ Answering failed: \(error)")
                return
            }
            DispatchQueue.main.async {
                withAnimation {
                    self.isIncomingCall = false
                    self.isCallActive = true
                    self.callStartTime = Date()
                }
            }
        }
    }
    
    private func declineCall() {
        print("⚡️ Call declined")
        
        self.calls.decline { error in
            if let error {
                print("❌ Declining failed: \(error)")
            }
        }
        
        withAnimation {
            isIncomingCall = false
        }
        
    }
    
    private func endCall() {
        self.calls.hangup { error in
            if let error {
                print("❌ Hanging up failed: \(error)")
            }
        }
        
        withAnimation {
            isCallActive = false
        }
        
    }
    
    private func logout() {
        // Forget the session.
        UserDefaults.standard.set(false, forKey: "isLoggedIn")
        UserDefaults.standard.removeObject(forKey: "domain")
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.removeObject(forKey: "password")
        
        // AppDelegate swaps the root view controller on this notification.
        NotificationCenter.default.post(name: NSNotification.Name("LogoutNotification"), object: nil)
    }
    
    private func setupNetworkErrorObserver() {
        // Surface network errors reported by the SIP layer.
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
    
    // MARK: - Call state at launch
    
    /// Catches a call that was already in progress, for instance when the
    /// application was relaunched during one.
    private func checkCallStateOnStartup() {
        // Delayed, so the UI has finished loading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Is there a call already?
            let callStatus = self.calls.getCurrentCallStatus()
            if callStatus != 0 { // 0 = no call
                print("⚡️ A call was already in progress at launch, updating the UI")
                
                // Who is calling.
                let caller = self.calls.getCurrentCallerInfo() as String? ?? "Intercom"
                callerInfo = caller.isEmpty ? "Intercom" : caller
                
                // Connected, or still ringing?
                if callStatus == 1 { // 1 = answered or active
                    withAnimation {
                        isIncomingCall = false
                        isCallActive = true
                        callStartTime = Date() // Approximate: the real start is lost.
                    }
                } else {
                    // Still ringing.
                    withAnimation {
                        isIncomingCall = true
                        isCallActive = false
                    }
                }
            }
            
            // Ask for a CallKit state check, in case the call was answered
            // from the system screen before this view existed.
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
