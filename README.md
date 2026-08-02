# CallWaveKit

CallWaveKit provides incoming SIP calls on iOS. The library owns SIP
registration, CallKit, PushKit and the PJSIP audio conference.

The repository contains the library and nothing else: `CallWaveKit` (the
Objective-C core), `CallWaveKitAsync` (the Swift concurrency layer), their
tests, and the bundled PJSIP binary. Integration examples live in
[CallWaveKit/README.md](CallWaveKit/README.md).

## Features

- incoming SIP calls — one by default, call waiting and CallKit hold when the
  engine is configured for more;
- two-way voice through the PJSIP conference bridge;
- microphone mute at the RTP capture connection, per call;
- answer, decline, hangup, mute and hold through CallKit;
- a configurable settle delay before `200 OK`, for PBXs that are not ready to
  be answered the moment they send the INVITE;
- a ring timeout that rejects an unanswered call with `480`;
- DTMF over RFC 2833 with a SIP INFO fallback;
- separate `host`, `port` and `transport` (UDP, TCP, TLS), with certificate
  verification on by default;
- optional SRTP, outbound proxy, separate digest user, custom REGISTER headers,
  STUN/ICE and codec priorities;
- SIP account replacement without recreating the PJSUA runtime, for
  credentials that arrive with every push;
- unregister and logout separately from stack teardown;
- PushKit wake-up handling with a correctly sequenced completion handler and a
  deadline, so the handler always runs;
- recovery from Wi-Fi/cellular handovers via `pjsua_handle_ip_change()`;
- per-call RTP/RTCP statistics;
- `os_log`-based logging with identifier redaction, a host sink, and no PJSIP
  protocol trace in release builds;
- a Swift concurrency layer: `AsyncStream` of events, `async throws` call
  actions;
- an optional host-owned mode in which the application keeps its own
  `CXProvider` and `PKPushRegistry`.

CallWaveKit does not make outgoing calls.

See [CHANGELOG.md](CHANGELOG.md) for the version history, including the
breaking changes in the current development version.

## Installation with CocoaPods

The repository includes a CocoaPods specification:

```ruby
pod 'CallWaveKit', path: '/path/to/CallWaveKit'
```

For a remote repository, use a semantic-version tag:

```ruby
pod 'CallWaveKit', git: 'https://github.com/PetrShtuka/CallWaveKit.git', tag: '0.3.0'
```

## Installation with Swift Package Manager

In Xcode select **File → Add Package Dependencies**, enter the repository URL,
select a version starting with `0.3.0`, and add the `CallWaveKit` product to the
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
    host: "sip.example.com",
    port: 5060,
    transport: .UDP,
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
reference for the client lifetime. Between calls use `unregister()` or
`logout()`; `stop()` destroys the PJSUA runtime and is for teardown only.

An application that already owns a `CXProvider` or a `PKPushRegistry` passes
`options: []` and its own provider instead, and drives the client from its own
delegates. See [CallWaveKit/README.md](CallWaveKit/README.md) for that mode,
for per-push credentials, for DTMF and for the audio-session hooks.

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

## Privacy manifest

`CallWaveKit/PrivacyInfo.xcprivacy` ships inside the library's resource bundle,
which App Store submission requires of a third-party SDK. CallWaveKit declares
no tracking, no collected data and no required-reason API usage; the bundled
PJSIP binary was checked for those APIs and uses none of them. Re-run that check
if you rebuild the XCFramework with different options.

## Tests

```sh
./Scripts/run-package-tests.sh
```

The script picks an available simulator on its own. `ACTION=build` compiles
without running the tests, and `DESTINATION=…` overrides the simulator.

The same script, a device-slice build and a podspec lint run on every push and
pull request — see [.github/workflows/ci.yml](.github/workflows/ci.yml). The
lint builds the pod into a synthetic application, which is what keeps the
CocoaPods integration covered.

## Requirements

- iOS 15.0 or later;
- Xcode 16 or later;
- CocoaPods or Swift Package Manager;
- bundled PJSIP 2.17 XCFramework.

The checked-in `PJSIP.xcframework` was built with a minimum of iOS 16.0. It links
into an application targeting iOS 15.0, but every object file produces a
`built for newer 'iOS' version` linker warning. Rebuild it to silence them:

```sh
MIN_IOS_VERSION=15.0 ./Scripts/build-pjsip-xcframework.sh
```

## Rebuilding PJSIP

The checked-in binary can be reproduced with:

```sh
./Scripts/build-pjsip-xcframework.sh
```

The script builds PJSIP 2.17 for iOS 15.0 or later. Override
`PJSIP_VERSION`, `MIN_IOS_VERSION`, or `BUILD_JOBS` when necessary.

The XCFramework is 21 MB and every clone pays for it. For a tagged release,
attach the zip instead and point the binary target at its URL:

```sh
./Scripts/package-pjsip-release.sh 0.3.0
```

The script prints the archive's checksum and the `.binaryTarget(url:checksum:)`
snippet to paste into `Package.swift`.

PJSIP is distributed under GPLv2 or a separate commercial license. Review
`Vendor/PJSIP-COPYING`, `Vendor/ThirdPartyLicenses`, and obtain the appropriate
license before distributing a closed-source application.

## License

MIT. See [LICENSE](LICENSE).
