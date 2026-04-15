import Foundation
import Combine

/// Protocol for audio/media management during SIP calls.
public protocol SIPMediaManagerProtocol: AnyObject {

    /// Activate the audio device for a call.
    func activateAudioDevice() throws

    /// Deactivate the audio device after a call.
    func deactivateAudioDevice() throws

    /// Set the audio output route (speaker, receiver, bluetooth, etc.).
    func setAudioRoute(_ route: SIPAudioRoute) throws

    /// Set microphone mute state.
    func setMuted(_ muted: Bool) throws

    /// Current mute state.
    var isMuted: Bool { get }

    /// Current audio route.
    var currentRoute: SIPAudioRoute { get }

    /// Publisher for audio route changes (delivers on main queue).
    var routePublisher: AnyPublisher<SIPAudioRoute, Never> { get }

    /// Get list of available audio routes.
    var availableRoutes: [SIPAudioRoute] { get }
}
