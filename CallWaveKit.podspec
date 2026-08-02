Pod::Spec.new do |spec|
  spec.name = 'CallWaveKit'
  spec.version = '0.2.0'
  spec.summary = 'Instance-owned incoming SIP calling for iOS with CallKit.'
  spec.description = <<-DESC
    CallWaveKit owns a PJSUA runtime, SIP registration, incoming audio calls,
    CallKit coordination, PushKit wake-up handling, two-way audio, RTP mute,
    DTMF and network-change recovery.
  DESC
  spec.homepage = 'https://github.com/PetrShtuka/CallWave'
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.author = { 'Petr Shtuka' => 'pitmailcom@gmail.com' }
  spec.source = { git: 'https://github.com/PetrShtuka/CallWave.git', tag: spec.version.to_s }

  spec.platform = :ios, '15.0'
  spec.requires_arc = true
  spec.swift_versions = ['5.9']

  # Objective-C core plus the Swift concurrency layer. Under CocoaPods both end
  # up in the single `CallWaveKit` module; under SwiftPM the Swift half is a
  # separate `CallWaveKitAsync` target, which is why it guards its import with
  # `#if SWIFT_PACKAGE`.
  spec.source_files = 'CallWaveKit/**/*.{h,m}', 'CallWaveKitAsync/**/*.swift'
  spec.public_header_files = 'CallWaveKit/include/*.h'
  spec.module_name = 'CallWaveKit'

  spec.resource_bundles = {
    'CallWaveKit' => ['CallWaveKit/PrivacyInfo.xcprivacy']
  }

  spec.vendored_frameworks = 'Vendor/PJSIP.xcframework'
  spec.frameworks = 'AVFoundation', 'AudioToolbox', 'CallKit', 'CFNetwork',
                    'CoreAudio', 'CoreFoundation', 'Network', 'PushKit', 'UIKit'
  spec.libraries = 'm', 'pthread'
  spec.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) PJ_AUTOCONF=1',
    'USER_HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/CallWaveKit ' \
                                  '$(PODS_TARGET_SRCROOT)/CallWaveKit/include'
  }
end
