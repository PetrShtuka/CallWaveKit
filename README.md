# CallWaveSIP

A modular iOS SIP/VoIP library built on PJSIP. Provides a clean Swift API for calls, registration, CallKit, and VoIP push.

## Architecture

```
┌──────────────────────────────────────────┐
│          CallWaveSIP (Public API)         │  ← Single entry point
├──────────┬───────────┬────────┬──────────┤
│ Account  │   Call    │ Media  │ CallKit  │  ← Manager layer
│ Manager  │  Manager  │Manager │ Adapter  │
├──────────┴───────────┴────────┴──────────┤
│            SIPEngine (Swift)             │  ← Thread-safe wrapper
├──────────────────────────────────────────┤
│       PJSIPEngine (Objective-C)          │  ← Low-level PJSIP bridge
├──────────────────────────────────────────┤
│            PJSIP C Library               │
└──────────────────────────────────────────┘
```

## Installation (SPM + CocoaPods)

The SDK is distributed via **Swift Package Manager**.  
PJSIP (the underlying C library) is installed via **CocoaPods** in your app.

### Step 1 — Add PJSIP to your app via CocoaPods

```ruby
# Podfile
platform :ios, '16.0'

target 'YourApp' do
  use_frameworks!
  pod 'pjsip'
end
```

```bash
pod install
```

Open the generated `.xcworkspace` (not `.xcodeproj`).

### Step 2 — Add CallWaveSIP via SPM

In Xcode (with `.xcworkspace` open):

1. **File → Add Package Dependencies...**
2. Enter the repository URL:
   ```
   https://github.com/your-org/CallWaveSIP.git
   ```
3. Select version rule → **Add Package**
4. Check `CallWaveSIP` library → **Add to Target: YourApp**

For local development, use a local path instead:

1. **File → Add Package Dependencies → Add Local...**
2. Select the `CallWave` directory

## Quick Start

```swift
import CallWaveSIP

// 1. Create an instance — you own its lifecycle
let sip = CallWaveSIP()

// 2. Initialize
try sip.initialize(configuration: .init(
    transport: .init(udpEnabled: true, tcpEnabled: true),
    codecs: .init(vadEnabled: false),
    nat: .init(stunServer: "stun.l.google.com:19302", iceEnabled: true),
    maxCalls: 30,
    logLevel: .info
))

// 3. Enable CallKit & VoIP Push
sip.enableCallKit(configuration: .init(localizedName: "My App"))
sip.enableVoIPPush()

// 4. Register a SIP account
try sip.account.register(with: .init(
    domain: "sip.example.com",
    port: 5060,
    username: "user",
    password: "password"
))

// 5. Listen to events (delegate or Combine)
sip.delegate = self
```

## Delegate

```swift
extension MyClass: CallWaveSIPDelegate {
    func callWaveSIP(_ sdk: CallWaveSIP, didReceiveIncomingCall call: SIPCall) { }
    func callWaveSIP(_ sdk: CallWaveSIP, callStateDidChange callID: SIPCall.ID, state: SIPCallState) { }
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeRegistrationState state: SIPRegistrationState) { }
    func callWaveSIP(_ sdk: CallWaveSIP, didChangeAudioRoute route: SIPAudioRoute) { }
    func callWaveSIP(_ sdk: CallWaveSIP, didEncounterError error: SIPError) { }
}
```

All delegate methods are optional (empty default implementations).

## Combine

```swift
sip.eventPublisher
    .sink { event in
        switch event {
        case .incomingCall(let call): ...
        case .callStateChanged(let id, let state): ...
        case .registrationStateChanged(let state): ...
        case .audioRouteChanged(let route): ...
        }
    }
    .store(in: &cancellables)
```

## Call Operations

```swift
try sip.calls.answer(callID: call.id)
try sip.calls.hangup(callID: call.id)
try sip.calls.hold(callID: call.id)
try sip.calls.resume(callID: call.id)
try sip.calls.sendDTMF(callID: call.id, digit: "5")

let outgoing = try sip.calls.makeCall(to: "sip:dest@example.com")

try sip.media.setMuted(true)
try sip.media.setAudioRoute(.builtInSpeaker)
```

## Modules

| Module | Description |
|---|---|
| `CallWaveSIP` | Public facade — main entry point |
| `SIPAccountManager` | Account registration lifecycle |
| `SIPCallManager` | Incoming/outgoing calls, DTMF, hold, transfer |
| `SIPMediaManager` | Audio routing, mute, speaker |
| `CallKitAdapter` | CXProvider integration |
| `VoIPPushHandler` | PushKit VoIP push handling |
| `SIPEngine` | Thread-safe Swift wrapper over PJSIP |
| `PJSIPEngine` | Low-level ObjC bridge (the only file calling `pjsua_*`) |

## Requirements

- iOS 16.0+
- Swift 5.9+
- PJSIP (via CocoaPods)

## License

MIT
