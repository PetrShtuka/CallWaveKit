# Migrating an intercom app from Linphone

CallWaveKit covers the incoming audio path used by an iOS intercom app. Keep
Linphone if your product needs outgoing calls, SIP video, transfer,
conferences, chat or presence.

| Linphone concept | CallWaveKit equivalent |
| --- | --- |
| `Core` lifecycle | One injected `CallWaveClient` |
| Proxy/account config | `CallWaveConfiguration` |
| NAT policy | `CallWaveEngineConfiguration` with STUN, ICE and TURN |
| Incoming-call callback | `CallWaveClientDelegate` or `events` |
| Call accept/terminate | `acceptCall` / `endCall` |
| DTMF | `sendDTMF` |
| Audio route control | `setSpeakerEnabled` plus route events |
| Call statistics | `statistics(forCallWithUUID:)` or periodic events |

## Host-owned CallKit

Majordom already owns its `CXProvider` and PushKit registration. Construct the
client with empty integration options and inject the existing provider:

```swift
let calls = CallWaveClient(
    configuration: nil,
    options: [],
    provider: provider,
    engineConfiguration: engine
)
try calls.startEngine()
```

Forward `CXAnswerCallAction`, `CXEndCallAction` and audio-session activation to
the matching CallWaveKit methods. Forward each VoIP push UUID through
`prepareIncomingCall(uuid:caller:)` before the INVITE arrives. The complete
flow lives in `Examples/IntercomDemo`.

Keep the RTSP preview in the application. CallWaveKit accepts caller metadata
and owns SIP audio; it does not link VLCKit or manage the camera stream.

## Rollout

Run both stacks behind a build-time switch for the first field build. Compare
REGISTER response codes, INVITE-to-answer delay, codec, packet loss and the end
reason from `diagnosticsSnapshot()`. Remove Linphone after the Major-ios field
check passes on Wi-Fi, cellular, Bluetooth and the locked-screen cold-launch
path.
