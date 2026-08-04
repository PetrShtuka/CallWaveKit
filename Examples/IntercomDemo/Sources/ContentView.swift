import SwiftUI

struct ContentView: View {
    @ObservedObject var coordinator: IntercomCallCoordinator

    var body: some View {
        NavigationView {
            Form {
                Section("Call") {
                    LabeledContent("State", value: coordinator.state)
                    LabeledContent("Caller", value: coordinator.caller)
                    Button("Answer in CallKit") { coordinator.answerCurrentCall() }
                    Button("End call", role: .destructive) { coordinator.endCurrentCall() }
                }

                Section("Intercom controls") {
                    Toggle("Speaker", isOn: $coordinator.speakerEnabled)
                    Toggle("Mute microphone", isOn: $coordinator.microphoneMuted)
                    Button("Open door (#)") { coordinator.openDoor() }
                }

                Section("Diagnostics") {
                    Button("Refresh snapshot") { coordinator.refreshDiagnostics() }
                    Text(coordinator.diagnostics)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Intercom")
        }
    }
}
