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

### Ending a ringing call and ending an established one

`endCall(uuid:)` and `declineCall(uuid:)` both send whatever the call's own
INVITE state calls for: a call that was never answered is closed with
`603 Decline` — a final response to its still-open INVITE — and an established
one with a BYE. The two entry points differ only in what the log says, so a
`CXEndCallAction` handler that cannot tell the two apart can keep calling
`endCall(uuid:)` for both. Use `declineCall(uuid:)` when the host does know the
call was never answered and wants the log to record it as a rejection.

The distinction still matters for what happens next. A BYE is a request inside
an established dialog and the PBX answers it with a `200 OK`. A `603` is a
response to an INVITE, and on UDP the peer confirms it with an ACK; until that
ACK arrives the transaction keeps retransmitting. Neither is finished when the
completion handler runs — see
[Releasing the account while a call is still ending](#releasing-the-account-while-a-call-is-still-ending)
before calling `logout()` or `stop()` next to it.

Both paths are logged, in the `call` category. A decline that worked:

```
[call] declining call 3 with 603: ended by the host (never answered, INVITE state EARLY)
[call] 603 handed to the transport for call 3
[call] 603 sent to 10.0.0.9:5060 for Call-ID 4f2c…, waiting for the ACK
[call] the peer ACKed 603, the teardown reached it
```

The third line is worth more than it looks: it is emitted from the transport
hand-off itself and carries the destination, so it separates "the response left
the device, addressed there" from "PJSUA accepted our call and nothing went out".
The fourth is the one that proves the PBX has it.

A `603` that reaches the wire but never gets acknowledged shows the first three
and then, once the transaction has given up:

```
[call] 603 for Call-ID 4f2c… was never ACKed within 32s. The peer never
       confirmed the teardown and may still have the call up.
```

And a teardown that was never generated at all has none of them, only:

```
[call] no SIP teardown for call 3 (ended by the host): PJSUA no longer knows this call
```

The phone shows the same clean decline in all three cases, so the log is the
only place they differ.

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

### Releasing the account while a call is still ending

Ending a call is not finished when `endCall(uuid:)`'s completion runs. PJSUA
hands the BYE or the `603` to the transaction layer and returns; the
retransmissions and the peer's acknowledgement happen afterwards, and PJSUA's
own header says the hangup "will continue in the background". `pjsua_acc_del`,
meanwhile, "always deletes the account regardless of active calls".

So `logout()` and `stop()` wait for it, and the wait covers **both** kinds of
teardown, which need tracking separately:

- **An established call ended with BYE** is tracked by PJSUA itself.
  `pjsua_call_get_count()` is documented to include "calls that are no longer
  active but still in the process of hanging up", and the call slot survives
  until the BYE transaction finishes.
- **A call declined with a final response** is not. PJSUA disconnects the invite
  session the moment a `603` is sent and releases the call slot, so its count is
  already back to zero while the response has not been acknowledged. CallWaveKit
  tracks these itself, by Call-ID and CSeq, from the transport hand-off until the
  ACK arrives.

Both are drained for up to one second — enough for a response whose first packet
was lost and had to be retransmitted — and the wait logs
`waiting for teardown: N call(s) hanging up, M final response(s) awaiting an ACK`
followed by `call teardown finished`, or a warning naming what was still
outstanding if it expires. `login(configuration:)` drains the same way when
replacing an account, because per-push credentials mean a new push can arrive
while the previous call is still ending.

Two consequences for the host:

- **`logout()` and `stop()` can block the calling thread for up to a second**
  after a call, so prefer calling them off the main queue. They return
  immediately when nothing is tearing down, which is the usual case.
- **`unregister()` does not drain and does not need to.** It sends
  `REGISTER Expires: 0` and leaves the account in place, which no in-flight
  INVITE transaction depends on.

There is no ordering requirement left for the host: `endCall(uuid:)` followed by
`logout()` on the next line is safe, because both go through the same serial SIP
queue in that order and `logout()` waits for what `endCall` started.

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

Deliver remote cancellation over the existing signalling connection or a
regular remote notification, rather than sending another VoIP push. Use the
same UUID:

```swift
try await calls.handleCancelledIncomingCall(uuid: callUUID, reason: .remoteEnded)
```

The method dismisses the pending CallKit call and records the cancellation. A
late INVITE with that UUID receives `603 Decline` instead of ringing again.
In managed CallKit mode, an actual VoIP payload marked as cancellation (or a
late announcement for a cancelled call) is still reported to CallKit and then
immediately ended. Duplicate announcements are reported with the same UUID so
CallKit can reject the duplicate without creating a second call. A transient
system UI may appear for a cancelled call; use the signalling cancellation API
to avoid it. In host-owned CallKit mode, the host remains responsible for
reporting every VoIP push and completing its PushKit handler.

`callWaveClientDidInvalidateVoIPPushToken(_:)` tells the host to remove the
token from its backend.

`handleVoIPPushPayload` parses `data.uuid` and `data.callerID`. For a different payload
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
          statistics.roundTripTime,
          statistics.experimentalEstimatedMOS)
}
```

`experimentalEstimatedMOS` is a simplified diagnostic estimate, not a
validated measurement for a particular codec, device or intercom. Do not use
it for SLAs or product analytics; make decisions from the raw loss, jitter and
round-trip-time values above.

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

`CallWaveLogLevelDebug` turns on the PJSIP protocol trace, which dumps whole
SIP messages. `Authorization` and `Proxy-Authorization` values are scrubbed
while `redactsIdentifiers` is on; the level still must not ship in a release
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

Every public method is safe to call from any thread, and so is every published
property. Internally the client keeps three rules.

**Every `pjsua_*` sequence the client initiates runs on one serial queue**, so a
"read the call info, then act on it" pair cannot interleave with another. PJSIP's
own callback threads talk to PJSUA directly — a `180 Ringing` that waits for a
queue hop arrives too late — and reach CallWaveKit state only through the
lock-protected call registry.

**The call projection changes on the main queue.** `callState`,
`currentCallUUID`, `currentCaller` and `microphoneMuted` belong to
`CallWaveCallStateMachine`, which is written from the main queue and nowhere
else — the same queue the delegate, the event observers and CallKit are driven
on, so an observer never sees half of a transition. The machine's own accessors
still take a lock, because the client's pass-throughs to them are read from any
thread: `resolveCallForUUID:` backs every argument-less call action.

**The rest of the published state is lock-protected rather than main-queue
bound.** `isRunning`, `registrationState`, `registrationError` and
`configuration` are written synchronously by `-start`, `-login…`, `-unregister`,
`-logout` and `-stop`, because those methods return to a caller that reads them
back immediately. Their accessors take a lock instead of relying on the calling
thread, so reading them from a PJSIP callback thread — or writing
`defaultCallerName` from one thread while another rings — is defined behaviour
rather than a torn read or an over-release. The same applies to the audio
coordinator's `currentAudioRoute`, which AVAudioSession republishes from its own
notification thread.

A property declared with a custom getter (`getter=isMicrophoneMuted`) has to
have *that* name implemented; writing `-microphoneMuted` instead leaves the real
getter auto-synthesized and unlocked. `CallWavePublishedStateConcurrencyTests`
under `-enableThreadSanitizer YES` catches it.

The properties that are read but never written after setup — `answerTimeout`,
`acceptDelay`, `incomingCallTimeout`, `pushCompletionTimeout`, `dtmfMethod` —
are plain scalars and are left unsynchronized on purpose. Set them before
`-start`, as the quick start does.

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
