import Foundation
import AVFoundation

/// Encapsulates all AVAudioSession configuration for VoIP calls.
final class SIPAudioSessionConfigurator {

    private let audioSession = AVAudioSession.sharedInstance()

    /// Configure audio session for an active VoIP call.
    func configureForCall() throws {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                    .mixWithOthers,
                    .defaultToSpeaker
                ]
            )
        } catch {
            throw SIPError.audioSessionActivationFailed(description: "Category setup failed: \(error.localizedDescription)")
        }
    }

    /// Activate the audio session.
    func activate() throws {
        do {
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            // Retry: deactivate then activate
            try? audioSession.setActive(false)
            Thread.sleep(forTimeInterval: 0.3)
            do {
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                throw SIPError.audioSessionActivationFailed(description: "Activation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Deactivate the audio session.
    func deactivate() {
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            sipLog(.warning, "Audio session deactivation failed: \(error)")
        }
    }

    /// Override audio output to speaker.
    func routeToSpeaker() throws {
        try audioSession.overrideOutputAudioPort(.speaker)
    }

    /// Route audio to the default receiver (earpiece).
    func routeToReceiver() throws {
        try audioSession.overrideOutputAudioPort(.none)
    }

    /// Detect the current active audio route.
    func detectCurrentRoute() -> SIPAudioRoute {
        let route = audioSession.currentRoute
        for output in route.outputs {
            switch output.portType {
            case .builtInSpeaker:
                return .builtInSpeaker
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
                return .bluetooth(name: output.portName)
            case .headphones:
                return .headphones
            case .headsetMic:
                return .headset
            case .carPlay:
                return .carPlay(name: output.portName)
            default:
                continue
            }
        }
        return .builtInReceiver
    }

    /// Get available audio routes based on connected devices.
    func getAvailableRoutes() -> [SIPAudioRoute] {
        var routes: [SIPAudioRoute] = [.builtInReceiver, .builtInSpeaker]

        if let inputs = audioSession.availableInputs {
            for input in inputs {
                switch input.portType {
                case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
                    routes.append(.bluetooth(name: input.portName))
                case .headsetMic:
                    routes.append(.headset)
                case .carPlay:
                    routes.append(.carPlay(name: input.portName))
                default:
                    break
                }
            }
        }

        // Check for headphones in outputs
        for output in audioSession.currentRoute.outputs {
            if output.portType == .headphones {
                routes.append(.headphones)
                break
            }
        }

        return routes
    }
}
