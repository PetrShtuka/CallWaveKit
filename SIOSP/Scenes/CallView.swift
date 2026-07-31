import SwiftUI
import AVFoundation

struct CallView: View {
    // MARK: - Properties
    let calls: AppCallService
    let callUUID: UUID
    let callerName: String
    let callerNumber: String
    let callStartTime: Date
    let onEnd: () -> Void
    
    @State private var callDuration: TimeInterval = 0
    @State private var speakerEnabled = false
    @State private var micMuted = false
    @State private var timerSubscription: Timer.TimerPublisher?
    @State private var timer: Timer?
    
    // MARK: - View Body
    var body: some View {
        ZStack {
            // Background
            Color.black
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Spacer()
                
                // Caller info
                VStack(spacing: 15) {
                    Text(callerName)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(callerNumber)
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text(formatDuration(callDuration))
                        .font(.title)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.top, 10)
                }
                
                Spacer()
                
                // Call controls
                HStack(spacing: 40) {
                    // Speaker button
                    Button(action: toggleSpeaker) {
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(speakerEnabled ? Color.white : Color.white.opacity(0.3))
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: speakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.3")
                                    .font(.system(size: 24))
                                    .foregroundColor(speakerEnabled ? .black : .white)
                            }
                            
                            Text("Динамик")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.top, 5)
                        }
                    }
                    
                    // Mute button
                    Button(action: toggleMute) {
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(micMuted ? Color.white : Color.white.opacity(0.3))
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(micMuted ? .black : .white)
                            }
                            
                            Text("Микрофон")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.top, 5)
                        }
                    }
                }
                .padding(.bottom, 40)
                
                // End call button
                Button(action: endCall) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 70, height: 70)
                        
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
                .padding(.bottom, 40)
            }
            .padding()
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }
    
    // MARK: - Methods
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            callDuration += 1
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        
        return formatter.string(from: interval) ?? "00:00:00"
    }
    
    private func toggleSpeaker() {
        let newValue = !speakerEnabled
        if self.calls.setSpeakerEnabled(newValue) {
            speakerEnabled = newValue
        }
    }
    
    private func toggleMute() {
        let newValue = !micMuted
        if self.calls.setMicrophoneMuted(newValue) {
            micMuted = newValue
        }
    }
    
    private func endCall() {
        // End the call
        self.calls.stopCall()
        
        // Call the completion handler
        onEnd()
    }
}

// MARK: - Preview
struct CallView_Previews: PreviewProvider {
    static var previews: some View {
        CallView(
            calls: AppCallService(),
            callUUID: UUID(),
            callerName: "Домофон",
            callerNumber: "22",
            callStartTime: Date(),
            onEnd: {}
        )
    }
}
