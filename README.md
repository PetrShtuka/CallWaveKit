# CallWaveKit

CallWaveKit provides incoming SIP calls on iOS. The library owns SIP
registration, CallKit, PushKit and the PJSIP audio conference.

The repository contains:

- `CallWaveKit`: the reusable library;
- `SIOSP`: a demo application that injects a `CallWaveClient`.

## Features

- one incoming SIP call at a time;
- two-way voice through the PJSIP conference bridge;
- microphone mute at the RTP capture connection;
- answer, decline and hangup actions through CallKit;
- SIP registration refresh and retry settings;
- PushKit wake-up handling.

CallWaveKit does not make outgoing calls.

## Installation with CocoaPods

The repository includes a CocoaPods specification:

```ruby
pod 'CallWaveKit', path: '/path/to/CallWave'
```

Run:

```sh
pod install
```

Open `SIOSP.xcworkspace` to run the demo.

For a remote repository, use a semantic-version tag:

```ruby
pod 'CallWaveKit', git: 'https://github.com/PetrShtuka/CallWave.git', tag: '0.1.0'
```

## Installation with Swift Package Manager

In Xcode select **File → Add Package Dependencies**, enter the repository URL,
select a version starting with `0.1.0`, and add the `CallWaveKit` product to the
application target. For local development, use **Add Local** and select this
repository directory.

The package includes `PJSIP.xcframework` with these slices:

- iOS device: `arm64`;
- iOS Simulator: `arm64` and `x86_64`.

No CocoaPods installation is required when using Swift Package Manager.

## Usage

```swift
import CallWaveKit

let configuration = CallWaveConfiguration(
    domain: "sip.example.com:5060",
    username: "1001",
    password: password,
    includesCallsInRecents: false
)

let calls = CallWaveClient(configuration: configuration)
calls.delegate = coordinator

try calls.start()
calls.registerForVoIPPushes()
```

Inject `calls` into the objects that need calling features. Keep a strong
reference for the client lifetime and call `stop()` when you release the SIP
session.

PJSUA exposes a process-wide C runtime. CallWaveKit returns
`CallWaveErrorEngineAlreadyRunning` if a second client calls `start()` while
another client owns that runtime.

## Host application settings

Add `NSMicrophoneUsageDescription` to the host application. Enable these
background modes:

- Audio;
- Voice over IP;
- Remote notifications.

The delegate receives the PushKit token. Your application sends that token to
your backend.

## Requirements

- iOS 16 or later;
- Xcode 16 or later;
- CocoaPods or Swift Package Manager;
- bundled PJSIP 2.17 XCFramework.

## Rebuilding PJSIP

The checked-in binary can be reproduced with:

```sh
./Scripts/build-pjsip-xcframework.sh
```

The script builds PJSIP 2.17 for iOS 16 or later. Override
`PJSIP_VERSION`, `MIN_IOS_VERSION`, or `BUILD_JOBS` when necessary.

PJSIP is distributed under GPLv2 or a separate commercial license. Review
`Vendor/PJSIP-COPYING`, `Vendor/ThirdPartyLicenses`, and obtain the appropriate
license before distributing a closed-source application.

## License

MIT. See [LICENSE](LICENSE).
