# Changelog

All notable changes to CallWaveKit are recorded here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until 1.0 a minor
bump may contain breaking changes, and each one is listed below.

## [Unreleased]

### Internal

- AVAudioSession ownership moved out of `CallWaveClient` into a new internal
  `CallWaveAudioSessionCoordinator`: category and activation, interruption and
  media-services-reset handling, speaker preference and its restoration across
  route changes, and the published audio route. PJSIP no longer appears in the
  audio-session code path — the coordinator asks its delegate (the client) to
  open or drop the sound device on the SIP queue. No public API changes.
- Per-call state transitions and the current-call projection (aggregate state,
  current call UUID, caller identity, microphone mute) moved out of
  `CallWaveClient` into a new internal `CallWaveCallStateMachine`, with the
  client as its delegate for state-change callbacks and events. This makes
  call-state races (push/INVITE/cancel, concurrent reporting) testable in
  isolation. No public API changes.

## [0.5.0] - 2026-08-15

### Security

- SIP `Authorization` and `Proxy-Authorization` credentials are now always
  removed from protocol traces, even when identifier redaction is disabled for
  field diagnostics. Folded authorization continuation lines are scrubbed too.

### Added

- Opus 1.5.2 is linked statically into every PJSIP slice, so
  `preferredCodecs` can now include `opus/48000/2` for wideband calls.
- SIP digest authentication with SHA-256 (RFC 8760) next to MD5, through a
  `pjproject` patch kept in `Patches/`. Servers that challenge with
  `algorithm=SHA-256` no longer fail registration.
- `CallWaveEventTypeCallQualityWarning` with `CallWaveCallQualityWarning`
  reasons (packet loss, high jitter, high round-trip time, no media). Each
  warning fires at most once per call and carries the statistics snapshot that
  tripped it. Thresholds and the watchdog live on `CallWaveEngineConfiguration`;
  the no-media watchdog can optionally end the call automatically.
- `CallWaveCallStatistics.experimentalEstimatedMOS`: an explicitly
  experimental simplified E-model estimate for diagnostics. It is not
  calibrated for a codec, device or deployment and must not be used for SLAs;
  raw loss, jitter and round-trip time remain the authoritative measurements.
- Voice service-type tagging (QoS) on SIP and RTP sockets, on by default and
  controlled by `CallWaveEngineConfiguration.QoSTaggingEnabled`.
- Quality monitoring now ticks once a second during an active call even when
  `statisticsUpdateInterval` is `0`; periodic statistics events stay opt-in.

### Changed

- SwiftPM resolves the rebuilt PJSIP binary from release
  `pjsip-2.17-ios15-opus-sha256.2` with checksum
  `f534773f4dc0e813d0e7a7e3be10a751804232721876d1bad286ab3cba0d16a4`. The
  build is still PJSIP 2.17 on Apple Network TLS with an iOS 15 floor; it adds
  Opus and SHA-256 on top. The immutable `.2` tag contains the build script,
  SHA-256 patch, build manifest and Opus license needed to reproduce the asset.

## [0.4.1] - 2026-08-04

### Licensing

- Clarified that CallWaveKit source is MIT while the bundled public PJSIP
  binary is GPL-2.0-or-later and remains separately licensed.
- Added the CallWaveKit maintainer's copyright without removing the retained
  copyright notice from earlier MIT-licensed work.
- Updated the CocoaPods metadata and added `LICENSING.md` so package consumers
  see both licences before distribution. This release contains no runtime or
  public API changes.

## [0.4.0] - 2026-08-04

### Added

- TURN over UDP, TCP or TLS through `CallWaveTURNConfiguration`.
- Dual-stack SIP and media with `automatic`, `ipv4Only` and `ipv6Only`
  policies. `automatic` supports IPv6-only and NAT64 networks.
- Audio route snapshots plus route-change and interruption events. The client
  restores the selected speaker route after audio-session reactivation when
  iOS still exposes that route.
- Remote cancellation for a call announced by PushKit. A late matching INVITE
  receives `603` and cannot create a second CallKit call.
- VoIP push-token invalidation callback and event.
- Credential-free diagnostics with registration, network path, audio route and
  RTP statistics. Hosts can request periodic raw statistics events.
- Async remote-cancellation API, DocC, an intercom demo and a Linphone migration
  guide.
- A thread-safe PushKit completion gate with a concurrent once-only test.

### Fixed

- PJSIP 2.17 now compiles with `PJ_SSL_SOCK_IMP_APPLE`, backed by
  `Network.framework`. The previous binary used `--disable-ssl` while the API
  exposed TLS.
- CI checks TLS symbols, XCFramework slices and the iOS 15 deployment floor.
  CocoaPods lint now fails on warnings.

### Release validation

- All 67 unit tests, the generic device build, strict Swift concurrency build,
  CocoaPods lint and the deterministic PJSIP binary verifier pass.
- The maintainer confirmed registration and a real incoming call with two-way
  audio on a physical iPhone through the Majordom PBX.
- SwiftPM resolves the immutable PJSIP 2.17 binary release with checksum
  `262e3341dd2d6b4737795902f76a11611709ed3a16908521f1700229e28c6bee`.

## [0.3.1] — 2026-08-02

### Fixed

- **Rejecting a call before its INVITE arrives now stops the caller ringing.**
  A VoIP push routinely beats the INVITE by a second or more, and the reject
  path — unlike the answer path, which polls for the call until `answerTimeout`
  — sent nothing to SIP when there was no call id yet. It deleted the pending
  record and returned `CallWaveErrorNoActiveCall`, so no `603`, `486` or `480`
  ever left the device. The INVITE then arrived to an empty registry, was
  answered `180 Ringing`, and became a *second* incoming call under a fresh
  UUID: the intercom kept ringing until `incomingCallTimeout`, and the host saw
  `.incoming` again after `.ended`.

  `-endCallWithUUID:completion:` and `-declineCallWithUUID:completion:` now
  keep the record and mark it cancelled instead of deleting it, report
  `CallWaveCallStateEnded` and complete without an error — the user's intent
  succeeded, so it is not a failure. `on_incoming_call` checks for such a
  cancellation before it rings, and answers `603 Decline` instead. Being the
  callee, it answers the INVITE; it does not send CANCEL.

  A cancellation expires after `answerTimeout`, so one whose INVITE never
  arrived cannot reject an unrelated later call, and a call still legitimately
  waiting for its INVITE always takes precedence over a pending cancellation.
  Nothing is reported to CallKit from this path: in host-owned mode the
  application owns the provider and ends the call from the state stream.

- **The bundled PJSIP binary is built for iOS 15.0 again.** It carried
  `minos 16.0` while the package declares iOS 15.0, so every application with a
  15.x deployment target linked it with a `built for newer 'iOS' version`
  warning per object file — 199 of them in one real consumer. The build script
  had already been lowered to 15.0; the XCFramework simply had not been rebuilt
  since. Every slice now reports `minos 15.0`: `ios-arm64` (arm64) and
  `ios-arm64_x86_64-simulator` (arm64 and x86_64).

  The rebuild is PJSIP 2.17 with the same options as before. The exported
  symbols are unchanged — 2241 before and after, with no additions or
  removals — the headers are untouched, and the XCFramework's `Info.plist` is
  byte-identical. The public API of CallWaveKit did not change.

## [0.3.0] — 2026-08-02

0.2.0 was staged during this work but never tagged or published, so it does
not appear here.

### Repository

- **The SIOSP demo application is gone.** It was a fork of an unrelated 2019
  project, it was the only reason the repository carried a CocoaPods
  integration and a MobileVLCKit dependency, and it hardcoded somebody's RTSP
  camera address. Integration examples live in `CallWaveKit/README.md`; the
  CocoaPods build stays covered by `pod lib lint`, which compiles the pod into
  a synthetic application.

### Breaking

- **TLS certificates are verified by default.** `CallWaveEngineConfiguration`
  ships with `verifiesTLSCertificate = YES`. An intercom with a self-signed
  certificate now fails to register until the host opts out explicitly. Only
  `CallWaveTransportTLS` is affected.
- **`defaultCallerName` replaces the hardcoded `"Домофон"`.** An unnamed caller
  is shown as `"Unknown"` unless the host sets its own name. A localized
  product name belongs in the application, not in the library.
- **Public headers moved to `CallWaveKit/include/`** and the API is split
  across several of them. `#import <CallWaveKit/CallWaveKit.h>` and
  `import CallWaveKit` are unchanged; direct file paths are not.
- **PJSIP no longer logs to stdout.** Everything goes through `CallWaveLog`,
  which defaults to `CallWaveLogLevelWarning` in release builds. The old
  behaviour was level 4 on the console, which prints whole SIP messages
  including `Authorization` headers.
- **`CallWaveCallStateHeld` was added** to `CallWaveCallState`. A `switch`
  over the enum without a `default` no longer compiles.
- The unused linphone-compatibility methods (`activateSoundDevice`,
  `getCurrentCallerInfo`, `getCurrentCallUUID`, `connectedCallWithUUID:`,
  `configureAudioSession`, `configureAudioRouting`, `changeOutputAudioPort:`)
  are gone. None of them were declared in a public header.

### Fixed

- **A disconnected call no longer ends the wrong CallKit call.** `on_call_state`
  used to resolve the call through `currentCallUUID`; a bidirectional
  `callId ↔ UUID` registry now resolves it by the call id PJSIP reported.
- **PJSUA is no longer called from arbitrary threads.** Ending a call, muting a
  call and answering all used to run `pjsua_*` on the main queue from the
  CallKit delegate while the serial SIP queue was doing its own work. Every
  sequence the client initiates now runs on that queue; PJSIP's own callback
  threads remain the documented exception.
- **`-isRegistered` no longer deadlocks** when called from the SIP queue, and
  `-dealloc` no longer resurrects the client by dispatching a block that
  captures `self`.
- **`on_incoming_call` no longer writes client state from a PJSIP thread.**
- **The PushKit completion handler always runs**, at the latest after
  `pushCompletionTimeout` (4 seconds by default). Never running it makes iOS
  stop delivering VoIP pushes to the application.
- **A successful un-REGISTER is reported as stopped, not registered.**

### Added

- **Network-change recovery.** An `NWPathMonitor` drives
  `pjsua_handle_ip_change()` on a Wi-Fi/cellular handover, so the device stays
  reachable. Turn it off with
  `CallWaveEngineConfiguration.handlesNetworkChanges`, or drive it manually
  with `-handleNetworkChange`. The client also nudges the registration when
  the application returns to the foreground unregistered.
- **`CallWaveEngineConfiguration`** for the PJSUA runtime: maximum calls, log
  level, user agent, ICE, STUN servers, codec priorities, TLS verification,
  echo-cancellation tail, voice activity detection.
- **`CallWaveConfigurationBuilder`** and
  `-[CallWaveConfiguration initWithBuilder:]` / `-configurationByApplying:` for
  the account settings that do not fit the old initializers: separate
  authentication user, realm, outbound proxy, registration expiry, keep-alive
  interval, SRTP policy (`CallWaveMediaEncryption`) and extra REGISTER headers.
- **Call waiting and hold.** With `maximumCalls > 1` a second INVITE is
  reported to CallKit instead of being answered `486 Busy Here`, and
  `CXSetHeldCallAction` is honoured. `-setHeld:forCallWithUUID:completion:`
  does the same without a CallKit transaction.
- **Per-call APIs**: `activeCallUUIDs`, `-stateForCallWithUUID:`,
  `-callerForCallWithUUID:`, `-setMicrophoneMuted:forCallWithUUID:completion:`
  and `-sendDTMF:method:forCallWithUUID:completion:`.
- **`-statisticsForCallWithUUID:`** returning `CallWaveCallStatistics`: packet
  counts, inbound and outbound loss, jitter, round-trip time and the
  negotiated codec.
- **`incomingCallTimeout`** — an unanswered call is rejected with
  `480 Temporarily Unavailable` and reported as unanswered after 60 seconds by
  default.
- **Structured errors.** `userInfo` now carries
  `CallWaveErrorSIPStatusCodeKey`, `CallWaveErrorPJStatusKey` and
  `CallWaveErrorOperationKey`, so a host can tell `403` from `408` in code.
  `registrationError` exposes the last registration failure.
  New codes: `CallWaveErrorCallLimitReached`, `CallWaveErrorUnsupportedOperation`.
- **Logging.** `CallWaveLog` with a level, a `CallWaveLogger` sink for the
  host's own stack, `os_log` output, and identifier redaction that is on by
  default.
- **Events.** `-addEventObserver:` / `-removeEventObserver:` deliver
  `CallWaveEvent` values on the main queue.
- **Swift concurrency layer** (`CallWaveKitAsync` under SwiftPM, the same
  module under CocoaPods): `client.events`,
  `client.events(forCallWithUUID:)`, `client.registrationStates` and
  `client.waitUntilRegistered(timeout:)`. The completion-handler methods
  already bridge to `async throws` on their own.
- **`pushPayloadParser`** for VoIP payloads that do not use
  `data.uuid` / `data.callerID`.
- **`PrivacyInfo.xcprivacy`**, required for an SDK distributed to third
  parties.
- **Unit tests and CI.** 42 tests over URI construction, domain parsing,
  configuration equality, caller-name formatting, DTMF normalization and the
  client's property contracts, plus a GitHub Actions workflow that runs them,
  builds the device slice and lints the podspec.
- **`Scripts/run-package-tests.sh`** and **`Scripts/package-pjsip-release.sh`**
  (zips the XCFramework and prints the SPM checksum, so a release can stop
  carrying 21 MB of binary in git).

## [0.1.0]

First distributable version: PJSUA runtime, SIP registration, one incoming
audio call, CallKit coordination, PushKit wake-up handling, two-way audio, RTP
mute, DTMF over RFC 2833 with a SIP INFO fallback, and a configurable settle
delay before `200 OK`.
