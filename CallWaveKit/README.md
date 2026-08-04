# CallWaveKit

`CallWaveKit` is an instance-owned iOS library for incoming SIP audio calls. It
coordinates PJSIP, CallKit, PushKit and `AVAudioSession`.

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
calls.defaultCallerName = "Front door"

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

## Engine settings

Everything that belongs to the PJSUA runtime rather than to an account lives on
`CallWaveEngineConfiguration`, which is read once, when the engine starts:

```swift
let engine = CallWaveEngineConfiguration.defaultConfiguration()
engine.maximumCalls = 2                        // call waiting and hold
engine.preferredCodecs = ["PCMA/8000", "PCMU/8000"]
engine.logLevel = .info
engine.stunServers = ["stun.example.com:3478"]
engine.isICEEnabled = true
engine.turnConfiguration = CallWaveTURNConfiguration(
    server: "turn.example.com:5349",
    transport: .TLS,
    username: turnUser,
    password: turnPassword
)
engine.ipVersionPolicy = .automatic             // IPv4, IPv6 and NAT64
engine.statisticsUpdateInterval = 5
engine.verifiesTLSCertificate = true           // the default

let calls = CallWaveClient(
    configuration: configuration,
    options: .managesEverything,
    provider: nil,
    engineConfiguration: engine
)
```

`verifiesTLSCertificate` defaults to `true`. An intercom with a self-signed
certificate will not register until the host turns it off deliberately.
TURN credentials stay out of standard logs, object descriptions and diagnostic
snapshots. Use `.ipv4Only` for an intercom that publishes unusable AAAA records
or accepts media on IPv4 only.

## Account settings

The builder covers the account fields that do not fit the plain initializers:

```swift
let configuration = CallWaveConfiguration { builder in
    builder.host = "sip.example.com"
    builder.username = "1001"
    builder.password = password
    builder.transport = .TLS
    builder.authenticationUsername = "1001@tenant"
    builder.realm = "example.com"
    builder.outboundProxy = "sip:proxy.example.com;transport=tls"
    builder.registrationExpiry = 120
    builder.keepAliveInterval = 15
    builder.mediaEncryption = .mandatory
    builder.additionalRegistrationHeaders = ["X-Tenant": "42"]
}

// Change one field without rebuilding the rest.
let rotated = configuration.applying { $0.password = newPassword }
```

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

Both intervals are logged at `CallWaveLogLevelInfo`, under the subsystem
`com.callwave.kit` and the category `call`, so a PBX that needs a different
value can be measured from the device console:

```
INVITE for call 5E2C… observed after 1840 ms, settle delay 500 ms
answering call 5E2C… after a 500 ms settle delay
200 OK sent for call 0
```

An incoming call that nobody answers is rejected with
`480 Temporarily Unavailable` and reported as unanswered after
`incomingCallTimeout` (60 seconds by default; `0` disables it).

## PushKit completion handler

Pass PushKit's handler through. The library invokes it from inside the
`reportNewIncomingCall` completion block, exactly once — acknowledging the push
before CallKit has accepted the call terminates the process with `0xBAADCA11`,
and never acknowledging it at all makes iOS stop delivering pushes to the
application. If CallKit has not called back within `pushCompletionTimeout`
(4 seconds) the handler runs anyway.

```swift
calls.handleVoIPPushPayload(payload.dictionaryPayload, completion: completion)
```

If the server sends a second push to retract the call, use the same UUID:

```swift
try await calls.handleCancelledIncomingCall(uuid: callUUID, reason: .remoteEnded)
```

The method dismisses the pending CallKit call and records the cancellation. A
late INVITE with that UUID receives `603 Decline` instead of ringing again.
`callWaveClientDidInvalidateVoIPPushToken(_:)` tells the host to remove the
token from its backend.

That method parses `data.uuid` and `data.callerID`. For a different payload
shape, install a parser rather than reimplementing the reporting sequence:

```swift
calls.pushPayloadParser = { payload in
    guard let call = payload["call"] as? [String: Any],
          let id = call["id"] as? String,
          let uuid = UUID(uuidString: id) else {
        return nil   // nil falls back to the built-in parsing
    }
    return CallWaveIncomingCallDescriptor(uuid: uuid, caller: call["from"] as? String)
}
```

`reportIncomingCall(uuid:caller:completion:)` still exists and parses nothing.

## DTMF

Intercom door openers are DTMF:

```swift
calls.sendDTMF("1234#") { error in … }
```

`dtmfMethod` defaults to `.auto`: RFC 2833 telephone-event in the RTP stream,
falling back to SIP INFO when the peer never negotiated telephone-event. Force
one with `sendDTMF(_:method:completion:)`. Reported calls advertise
`supportsDTMF`, so `CXPlayDTMFCallAction` works as well.
`CallWaveClient.normalizedDTMFDigits(_:)` shows what would actually be sent.

## Several calls at once

With `engineConfiguration.maximumCalls > 1` a second INVITE is reported to
CallKit instead of being answered `486 Busy Here`, calls advertise
`supportsHolding`, and `CXSetHeldCallAction` is honoured. Address individual
calls by UUID:

```swift
for uuid in calls.activeCallUUIDs {
    print(calls.caller(forCallWithUUID: uuid) ?? "-",
          calls.state(forCallWithUUID: uuid))
}
calls.setHeld(true, forCallWithUUID: first) { _ in }
calls.setMicrophoneMuted(true, forCallWithUUID: second) { _ in }
```

The argument-less `answer`, `hangup`, `setMuted` and `sendDTMF` keep acting on
the most recent call, so a single-call host needs no changes.

## Call quality

```swift
if let statistics = calls.statistics(forCallWithUUID: nil) {
    print(statistics.codec ?? "-",
          statistics.inboundLossFraction,
          statistics.jitter,
          statistics.roundTripTime)
}
```

## Audio session

CallKit does not always deliver `didActivate` — most often on a cold start
answered from the lock screen. The library activates the session itself 1.5
seconds after answering when that happens, and the same primitives are public:

```swift
try calls.configureAudioSession()   // category and mode, no activation
try calls.activateAudioSession()    // activate and open the PJSIP sound device
```

## Network changes

An `NWPathMonitor` watches for Wi-Fi/cellular handovers and drives
`pjsua_handle_ip_change()`, which rebuilds the transports and re-registers.
Without it the device silently stops being reachable after leaving Wi-Fi. Turn
it off with `engineConfiguration.handlesNetworkChanges` and call
`handleNetworkChange()` yourself if the host already tracks connectivity.

## Errors

Failures carry structured `userInfo`:

```swift
calls.login(configuration: configuration) { error in
    let error = error as NSError?
    let sipStatus = error?.userInfo[CallWaveErrorSIPStatusCodeKey] as? Int   // 403, 408, …
    let pjStatus  = error?.userInfo[CallWaveErrorPJStatusKey] as? Int
    let operation = error?.userInfo[CallWaveErrorOperationKey] as? String
}
```

`registrationError` holds the last registration failure while
`registrationState == .failed`.

## Logging

Nothing goes to stdout. `CallWaveLog` writes to `os_log` under the subsystem
`com.callwave.kit` and forwards to an optional host sink:

```swift
CallWaveLog.level = .info                // .warning in release builds by default
CallWaveLog.logger = myLogSink           // CallWaveLogger
CallWaveLog.redactsIdentifiers = true    // the default
```

`CallWaveLogLevelDebug` turns on the PJSIP protocol trace, which contains whole
SIP messages including `Authorization` headers. It must not ship in a release
build.

## Swift concurrency

Under SwiftPM the concurrency layer is the `CallWaveKitAsync` module; under
CocoaPods it is part of `CallWaveKit`.

```swift
import CallWaveKit
import CallWaveKitAsync   // SwiftPM only

for await event in calls.events where event.type == .incomingCall {
    await present(caller: event.caller)
}

try await calls.waitUntilRegistered(timeout: 15)
try await calls.acceptCall(uuid: callUUID)   // bridged from the completion API
```

`addEventObserver(_:)` / `removeEventObserver(_:)` are the Objective-C form of
the same thing.

## Threading

Every public method is safe to call from any thread. Internally the client keeps
two rules: its own mutable state changes on the main queue, which is also where
the delegate, the event observers and CallKit are driven; and every `pjsua_*`
sequence the client initiates runs on one serial queue, so a "read the call
info, then act on it" pair cannot interleave with another. PJSIP's own callback
threads talk to PJSUA directly — a `180 Ringing` that waits for a queue hop
arrives too late — and reach CallWaveKit state only through a lock-protected
call registry.

## Host application settings

The host application must enable the `audio`, `voip` and `remote-notification`
background modes and provide a microphone usage description. Push tokens are
delivered through `CallWaveClientDelegate`; the host remains responsible for
sending them to its backend.

## Installation

CocoaPods or Swift Package Manager. The SPM product is named `CallWaveKit` and
vends two modules, `CallWaveKit` and `CallWaveKitAsync`; it uses the bundled
PJSIP 2.17 XCFramework. The library requires iOS 15.0 or later; see the
repository README for the PJSIP binary's own minimum version.
