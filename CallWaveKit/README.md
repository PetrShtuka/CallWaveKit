# CallWaveKit

`CallWaveKit` is an instance-owned iOS library for one incoming SIP audio call
at a time. It coordinates PJSIP, CallKit, PushKit and `AVAudioSession`.

There are two integration modes. Pick the second one if the application already
runs its own `CXProvider` or its own `PKPushRegistry`.

## Library-owned CallKit and PushKit

The library creates the provider and the VoIP push registry, parses the push
payload and reports the call itself.

```swift
import CallWaveKit

let configuration = CallWaveConfiguration(
    host: "sip.example.com",
    port: 5060,
    transport: .UDP,
    username: "1001",
    password: password,
    includesCallsInRecents: false
)

let calls = CallWaveClient(configuration: configuration)
calls.delegate = callCoordinator

try calls.start()
calls.registerForVoIPPushes()
```

The application owns and injects `CallWaveClient`. There is no public singleton.
Because PJSUA itself has a process-global runtime, starting a second client while
another client is running returns `CallWaveErrorEngineAlreadyRunning`.

`CallWaveConfiguration(domain:username:password:includesCallsInRecents:)` still
exists and splits a trailing `:port`, but `host`/`port`/`transport` is the
explicit form. The identity URI is `sip:username@host` — no port, no transport
parameter — while the registrar URI is `sip:host:port` plus `;transport=` for TCP
and TLS. Transports are created on demand.

## Host-owned CallKit and PushKit

Two `CXProvider` instances, or two `.voIP` `PKPushRegistry` instances, in one
process desynchronise call state. Clear the corresponding option and the library
creates neither:

```swift
let calls = CallWaveClient(
    configuration: nil,          // credentials arrive with the push
    options: [],                 // the host owns CallKit and PushKit
    provider: brandedProvider    // used only to report termination
)
try calls.startEngine()
```

Then drive it from the host's own delegates:

```swift
// PKPushRegistryDelegate — the host reported the call to its own provider first.
calls.login(configuration: configuration(from: payload)) { _ in }
calls.prepareIncomingCall(uuid: callUUID, caller: callerName)

// CXProviderDelegate
func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    action.fulfill()                       // before CallKit's own deadline
    calls.acceptCall(uuid: action.callUUID) { error in
        if error != nil { /* report .failed */ }
    }
}

func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    calls.endCall(uuid: action.callUUID) { _ in action.fulfill() }
}

func provider(_ provider: CXProvider, didActivate session: AVAudioSession) {
    calls.audioSessionDidActivate(session)
}

func provider(_ provider: CXProvider, didDeactivate session: AVAudioSession) {
    calls.audioSessionDidDeactivate(session)
}
```

`callWaveClient(_:didEndCallWithUUID:reason:)` fires when the SIP side ends the
call. A host that keeps its provider private uses that callback to call
`reportCall(with:endedAt:reason:)` itself.

## Credentials that change per call

`login(configuration:completion:)` and `updateConfiguration(_:)` replace the SIP
account in place. The PJSUA runtime is never destroyed, so this is safe to run
from a VoIP push on every call — unlike a `stop()`/`start()` cycle, which means
`pjsua_destroy()`/`pjsua_create()` in the background. An identical configuration
only refreshes the registration.

Between calls, release the account without tearing the stack down:

```swift
try calls.unregister()   // REGISTER Expires: 0; account and stack stay alive
try calls.logout()       // also deletes the account; stack stays alive
calls.stop()             // pjsua_destroy(), for teardown only
```

## Answering: waiting for the INVITE, then letting the PBX settle

PushKit routinely wakes the app before the SIP INVITE. `acceptCall(uuid:…)`
polls for the call until `answerTimeout` (10 seconds by default) and then fails
with `CallWaveErrorTimedOut`, so the CallKit action can be fulfilled immediately
instead of being held past CallKit's own deadline. In library-owned mode
`performAnswerCallAction:` already does exactly that.

Once the call is found, the answer waits out `acceptDelay` before `200 OK` goes
out. Intercom PBXs are not always ready to accept the answer the moment they
have sent the INVITE, and answering too early tears the call down:

```swift
calls.acceptDelay = 0.5   // the default
```

Values are clamped to `[0, 1.0]`. The 0.5 default is the pause the previous
linphone-based implementation used; the one-second ceiling exists because
CallKit already shows the call as connected while the pause runs, so a longer
one reads to the user as a call that does not work. Set `0` to answer as soon
as the INVITE is seen — that path adds no dispatch hop at all.

The pause is applied once per call and only after the INVITE has been found. It
is not part of `answerTimeout`: an expired timeout stops the wait for the
INVITE, it does not cancel a pause already under way. When the intercom cancels
the call during the pause, the answer is skipped and the completion reports
`CallWaveErrorNoActiveCall`.

Both intervals are logged, so a PBX that needs a different value can be
measured from the device console:

```
SIP: INVITE for call 5E2C… observed after 1840 ms, settle delay 500 ms
SIP: answering call 5E2C… after a 500 ms settle delay
SIP: 200 OK sent for call 0
```

## PushKit completion handler

Pass PushKit's handler through. The library invokes it from inside the
`reportNewIncomingCall` completion block, exactly once — acknowledging the push
before CallKit has accepted the call terminates the process with `0xBAADCA11`
and eventually bans VoIP pushes for the app.

```swift
calls.handleVoIPPushPayload(payload.dictionaryPayload, completion: completion)
```

That method parses `data.uuid` and `data.callerID`. For any other payload format,
extract the values yourself and call `reportIncomingCall(uuid:caller:completion:)`,
which parses nothing.

## DTMF

Intercom door openers are DTMF:

```swift
calls.sendDTMF("1234#") { error in … }
```

`dtmfMethod` defaults to `.auto`: RFC 2833 telephone-event in the RTP stream,
falling back to SIP INFO when the peer never negotiated telephone-event. Force
one with `sendDTMF(_:method:completion:)`. Reported calls advertise
`supportsDTMF`, so `CXPlayDTMFCallAction` works as well.

## Audio session

CallKit does not always deliver `didActivate` — most often on a cold start
answered from the lock screen. The library activates the session itself 1.5
seconds after answering when that happens, and the same primitives are public:

```swift
try calls.configureAudioSession()   // category and mode, no activation
try calls.activateAudioSession()    // activate and open the PJSIP sound device
```

## Host application settings

The host application must enable the `audio`, `voip` and `remote-notification`
background modes and provide a microphone usage description. Push tokens are
delivered through `CallWaveClientDelegate`; the host remains responsible for
sending them to its backend.

## Installation

CocoaPods or Swift Package Manager. The SPM product is named `CallWaveKit` and
uses the bundled PJSIP 2.17 XCFramework. The library requires iOS 15.0 or later;
see the repository README for the PJSIP binary's own minimum version.
