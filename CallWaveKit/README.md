# CallWaveKit

`CallWaveKit` is an instance-owned iOS library for one incoming SIP audio call
at a time. It coordinates PJSIP, CallKit, PushKit and `AVAudioSession`.

```swift
import CallWaveKit

let configuration = CallWaveConfiguration(
    domain: "sip.example.com:5060",
    username: "1001",
    password: password,
    includesCallsInRecents: false
)

let calls = CallWaveClient(configuration: configuration)
calls.delegate = callCoordinator

try calls.start()
```

The application owns and injects `CallWaveClient`. There is no public
singleton. Because PJSUA itself has a process-global runtime, starting a second
client while another client is running returns
`CallWaveErrorEngineAlreadyRunning`.

The host application must enable the `audio`, `voip` and
`remote-notification` background modes and provide a microphone usage
description. Push tokens are delivered through `CallWaveClientDelegate`; the
host remains responsible for sending them to its backend.

The library can be installed through CocoaPods or Swift Package Manager. The
SPM product is named `CallWaveKit` and uses the bundled PJSIP 2.17 XCFramework.
