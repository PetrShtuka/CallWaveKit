# Field testing CallWaveKit

`Scripts/run-package-tests.sh` covers URI construction, configuration equality,
caller-name formatting, DTMF normalization and the client's property contracts.
It cannot cover the part that actually breaks: a real PBX, a real VoIP push, a
real lock screen and a real audio session. Everything in this file has to be
done by hand, on a device, against an intercom.

Run it before tagging a release, and after any change to the answer path, the
push path, the audio session or the registration lifecycle.

## 0.4.0 release record

On 2026-08-04 the maintainer confirmed registration and a real incoming call
with two-way audio on a physical iPhone through the Majordom PBX. Automated CI
also passed the simulator unit suite, generic device build, strict concurrency,
CocoaPods lint and PJSIP binary verification. Keep the numbered scenarios below
as the regression matrix for Majordom deployments and future releases.

## Setup

- A physical iPhone. The Simulator has no PushKit and no usable audio route.
- An intercom (or PBX) that calls the account, and a door the DTMF code opens.
- A host application build with the library's logging opened up:

```swift
CallWaveLog.level = .debug
CallWaveLog.redactsIdentifiers = false   // never in a build you ship
```

  Redaction is on by default, so without that second line every UUID, caller and
  registrar reads `<private>` and the scenarios below cannot be followed. At
  `.debug` the PJSIP protocol trace includes `Authorization` headers — this is a
  debugging build, not a TestFlight build.

- Console output, filtered on the library's subsystem:

```sh
log stream --predicate 'subsystem == "com.callwave.kit"' --info --debug
```

  Categories are `sip`, `call`, `audio`, `push`, `network` and `pjsip`, all
  lower-case. Narrow with `--predicate 'subsystem == "com.callwave.kit" AND
  category == "call"'`.

Markers below are written as `[category] message`, matching what `log stream`
prints for the subsystem and category. Only the message text is emitted by the
library; the bracket is shorthand for the category column.

Record the log for every scenario. A failure with no log is a failure that has
to be reproduced from scratch.

## Scenarios

Each one lists what to do, what must happen, and the marker that proves it.

### 1. Cold start, locked screen

The single most fragile path: the application is not running, the phone is
locked, the call is answered from the lock screen.

Force-quit the app, lock the phone, place the call, answer from the lock screen.

- CallKit shows the branded name and icon.
- Two-way audio within a second of answering — **check both directions**, the
  common failure is one-way.
- `[call] INVITE for call … observed after N ms, settle delay 500 ms`, then
  `[call] answering call … after a 500 ms settle delay`, then
  `[call] 200 OK sent for call 0`.
- Note the `N`. If it creeps toward `answerTimeout`, the PBX or the push path
  got slower and the timeout needs revisiting.
- `[audio] CallKit did not activate the session, activating manually` is a
  warning, not a failure — but if it appears on every call, CallKit is not
  activating the session at all and that deserves an investigation of its own.

### 2. Foreground and background

Repeat scenario 1 with the app in the foreground, then backgrounded but running.
All three must behave identically; they exercise different wake-up paths.

### 3. Opening the door

Answer, then send the DTMF code.

- The door opens.
- The call ends only **after** the digits have gone out — hanging up inside the
  DTMF completion is the contract; ending the call earlier truncates the RTP
  telephone-events and the door stays shut.
- If the PBX does not negotiate `telephone-event`, the log shows the RFC 2833
  attempt failing and the SIP INFO fallback being used:
  `[call] RFC 2833 DTMF failed (…), retrying with SIP INFO`. Both are
  acceptable; silently no door is not.

### 4. Declining

Three separate cases, all of which must leave the intercom silent:

1. Decline **after** the INVITE has arrived (roughly a second after the phone
   starts ringing).
2. Decline **before** the INVITE has arrived — press it the instant CallKit
   appears. The INVITE lands after the decline, and the intercom must still stop
   ringing. There must be **no second** `call state … incoming` with a different
   UUID afterwards, and no call left ringing on the PBX.
3. Ignore the call entirely and let CallKit time it out.

Case 2 is a regression test: it failed in 0.3.0 and earlier, where the decline
was dropped because the SIP call did not exist yet, and the late INVITE then rang
as a second call. Fixed in 0.3.1 — the marker that proves the fix ran is
`[call] INVITE for call … arrived after the user rejected it; answered 603`.

### 5. The intercom hangs up

Answer, then hang up on the intercom side.

- The CallKit screen disappears on its own; no stuck call in the UI.
- `didEndCallWithUUID:reason:` fires once, with the UUID of the call that
  actually ended.

### 6. Nobody answers

Let the phone ring past `incomingCallTimeout` (60 s by default).

- The call is rejected with `480`, `[call] call … rang for 60s without an answer`
  appears, and CallKit clears.
- The next call still arrives — the timeout must not leave the account in a bad
  state.

### 7. Ten calls in a row

Place ten calls, answering some and declining others, with the app left running
between them.

- Every call arrives. A call that does not arrive after a successful earlier one
  means the registration was not restored — check `unregister()` / `login()`
  ordering in the host.
- If the host receives credentials in the push, use an account whose credentials
  actually change between calls, so the account swap is exercised rather than
  the "identical configuration, just re-register" shortcut.
- Watch for `[sip] registration started for … via …` per call and a `200` in
  `[sip] registration 200 …`.

### 8. Unregistering between calls

A host that releases the account between calls does it through `unregister()`,
and the state that follows has to be believable: a client that claims to be
registered when it is not makes the host skip the re-registration, and the next
call simply never arrives.

After a finished call, call `unregister()` and read the state back.

- `registrationState` is `.stopped` and `isRegistered` is `false`. Reporting
  `.registered` here is the 0.3.0 bug — PJSIP leaves `expires` at
  `PJSIP_EXPIRES_NOT_SPECIFIED` rather than at zero, with the status still 200.
- `unregister()` a second time still succeeds instead of reporting an error.
- `refreshRegistration()` or `login(configuration:)` brings it back, and the
  next call arrives.

### 9. Two calls at once

With `maximumCalls == 1` (the default), have a second intercom call while the
first is up: the second must be rejected `486 Busy Here` and the first must
survive untouched.

With `maximumCalls > 1`, the second call is reported to CallKit, hold works, and
audio follows the active call. With both calls up, end **one** of them: the
other must survive with its audio intact. Ending the wrong one is the 0.3.0 bug,
where a disconnect was resolved through `currentCallUUID` instead of the call id
PJSIP actually reported.

### 10. Network handover mid-call

Answer, then switch Wi-Fi off during the conversation.

- Audio recovers, or the call ends cleanly. What must not happen is a call that
  looks alive with no audio in either direction.
- `[network] network path changed (0x… -> 0x…), rebuilding transports` — this
  is the line that proves `pjsua_handle_ip_change()` ran. A failure logs
  `[network] IP change handling failed (…)`.

### 11. Push survival

Twenty calls over a session, some answered, some declined, some ignored.

- The process is never killed with `0xBAADCA11`.
- Pushes still arrive at call twenty. iOS stops delivering VoIP pushes to an
  application that fails to run the PushKit completion handler, and the
  punishment is delayed — which is exactly why this needs twenty calls and not
  two.
- `[push] acknowledging VoIP push (…)` appears once per push.

### 12. Audio details

During an answered call:

- Mute, and confirm the **other side stops hearing you** — CallWaveKit mutes at
  the RTP capture connection, so a mute that only changes the button is a bug.
- Speaker on and off.
- Plug in wired headphones, then a Bluetooth headset, mid-call.
- `statistics(forCallWithUUID:)` reports a sane codec, non-zero packet counts
  and plausible loss and jitter.

### 13. TLS, if the deployment uses it

Certificate verification is on by default since 0.3.0. Register against the
intercom over TLS and confirm it succeeds; if the intercom carries a self-signed
certificate, confirm that the host's explicit opt-out is what makes it work, and
that removing the opt-out fails the registration rather than silently accepting
the certificate.

### 14. Remote cancellation

Send an incoming-call push, then send a cancellation push with the same UUID
before the INVITE arrives. Repeat after the INVITE reaches the device.

- CallKit clears once and no second incoming screen appears.
- A late INVITE receives `603`.
- The next normal call arrives and answers.

### 15. Audio interruption and route loss

Answer with a Bluetooth headset, interrupt the app with a normal phone call,
then return. Disconnect Bluetooth during a second call and reconnect it.

- CallWaveKit emits interruption and route-change events.
- Audio resumes after the phone call when iOS supplies `shouldResume`.
- The session falls back to an available route after Bluetooth disappears.
- A selected speaker route returns after reactivation when iOS still exposes
  the speaker.

### 16. IPv6, NAT64 and TURN

Register on an IPv6-only/NAT64 network with `.automatic`, then force media
through each supported TURN transport. Repeat an old IPv4 intercom with
`.ipv4Only`.

- REGISTER and the incoming call complete on IPv6-only service.
- RTP counters increase through TURN UDP, TCP and TLS.
- Logs and `diagnosticsSnapshot()` contain no TURN username or password.

## Reporting a field failure

Attach the console log for the whole call, from the push to the end, and state:

- which scenario number, and which of the three app states (cold, foreground,
  background);
- the intercom or PBX model and the transport;
- the `N` from `INVITE … observed after N ms`;
- what the user saw, separately from what the log says.

## Keeping this file honest

Every bug found in the field becomes a numbered scenario here, in the same
release as the fix. A bug that is fixed without a scenario added is a bug that
comes back — the decline-before-INVITE case in scenario 4 is exactly that, and
it reached production because nothing on this list would have caught it.
