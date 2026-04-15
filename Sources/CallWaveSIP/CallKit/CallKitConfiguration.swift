import Foundation
import CallKit

/// Configuration for the CallKit integration layer.
public struct CallKitConfiguration: Sendable {
    /// Localized name shown in the system call UI.
    public let localizedName: String
    /// Icon template image data for the call UI.
    public let iconTemplateImageData: Data?
    /// Custom ringtone sound file name.
    public let ringtoneSound: String?
    /// Whether video calls are supported.
    public let supportsVideo: Bool
    /// Maximum calls per call group.
    public let maximumCallsPerCallGroup: Int
    /// Supported handle types for caller identification.
    public let supportedHandleTypes: Set<CXHandle.HandleType>

    public init(
        localizedName: String,
        iconTemplateImageData: Data? = nil,
        ringtoneSound: String? = nil,
        supportsVideo: Bool = false,
        maximumCallsPerCallGroup: Int = 1,
        supportedHandleTypes: Set<CXHandle.HandleType> = [.phoneNumber, .generic]
    ) {
        self.localizedName = localizedName
        self.iconTemplateImageData = iconTemplateImageData
        self.ringtoneSound = ringtoneSound
        self.supportsVideo = supportsVideo
        self.maximumCallsPerCallGroup = maximumCallsPerCallGroup
        self.supportedHandleTypes = supportedHandleTypes
    }
}
