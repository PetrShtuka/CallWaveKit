Pod::Spec.new do |spec|
  spec.name = 'CallWaveKit'
  spec.version = '0.1.0'
  spec.summary = 'Instance-owned incoming SIP calling for iOS with CallKit.'
  spec.description = <<-DESC
    CallWaveKit owns a PJSUA runtime, SIP registration, one incoming audio call,
    CallKit coordination, PushKit wake-up handling, two-way audio and RTP mute.
  DESC
  spec.homepage = 'https://github.com/PetrShtuka/CallWave'
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.author = { 'CallWave' => 'support@example.com' }
  spec.source = { git: 'https://github.com/PetrShtuka/CallWave.git', tag: spec.version.to_s }

  spec.platform = :ios, '15.0'
  spec.requires_arc = true
  spec.source_files = 'CallWaveKit/**/*.{h,m}'
  spec.public_header_files = 'CallWaveKit/CallWaveKit.h', 'CallWaveKit/CallWaveClient.h'
  spec.module_name = 'CallWaveKit'
  spec.vendored_frameworks = 'Vendor/PJSIP.xcframework'
  spec.frameworks = 'AVFoundation', 'AudioToolbox', 'CallKit', 'CFNetwork',
                    'CoreAudio', 'CoreFoundation', 'PushKit', 'UIKit'
  spec.libraries = 'm', 'pthread'
  spec.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) PJ_AUTOCONF=1'
  }
end
