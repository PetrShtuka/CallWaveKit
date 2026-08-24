# CallWaveKit

[![CI](https://github.com/PetrShtuka/CallWaveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/PetrShtuka/CallWaveKit/actions/workflows/ci.yml)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![CocoaPods](https://img.shields.io/badge/CocoaPods-compatible-brightgreen.svg)](https://cocoapods.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey.svg)](#requirements)

**Incoming SIP SDK for iOS intercoms.** CallWaveKit owns a PJSIP runtime, SIP
registration, CallKit, PushKit and the audio session. The host injects and
drives one client instance.

It was built for door intercoms — a call arrives by VoIP push, the user answers
from the lock screen, talks, and sends a DTMF digit to open the door — and it is
deliberately narrow: **CallWaveKit does not place outgoing calls.**

## Licensing: read this before shipping

CallWaveKit source is MIT. **The PJSIP binary it bundles is not.** The public
binary is GPL-2.0-or-later. Applications distributing that binary must comply
with the GPL for the resulting program or obtain an appropriate alternative
PJSIP licence directly from Teluu.

Read [LICENSING.md](LICENSING.md), `Vendor/PJSIP-COPYING` and
`Vendor/ThirdPartyLicenses` before distribution. Installing the package does
not grant or transfer a proprietary PJSIP licence.

## Requirements

- iOS 15.0 or later;
- Xcode 15 or later (the package manifest is `swift-tools-version: 5.9`;
  development and CI run on Xcode 26);
- Swift Package Manager or CocoaPods.

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies**, enter
`https://github.com/PetrShtuka/CallWaveKit.git`, pick version `0.6.0` or later,
and add the `CallWaveKit` product to your application target.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/PetrShtuka/CallWaveKit.git", from: "0.6.0")
```

The product vends two modules: `CallWaveKit` (the Objective-C API) and
`CallWaveKitAsync` (Swift concurrency on top of it). Nothing else is needed —
SwiftPM downloads the checksum-pinned `PJSIP.xcframework` release asset, with
`arm64` for the device and `arm64` plus `x86_64` for the simulator.

### CocoaPods

```ruby
pod 'CallWaveKit', '~> 0.6'
```

Both modules land in a single `CallWaveKit` module under CocoaPods, so
`import CallWaveKit` is enough.

To track the repository directly instead of the published pod — an unreleased
fix, say — point at the tag:

```ruby
pod 'CallWaveKit', git: 'https://github.com/PetrShtuka/CallWaveKit.git', tag: '0.6.0'
```

## Host application settings

Add `NSMicrophoneUsageDescription` to your `Info.plist` and enable three
background modes: **Audio**, **Voice over IP** and **Remote notifications**.
Without the VoIP mode the push never wakes the application.

## Quick start

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
calls.defaultCallerName = "Front door"

try calls.start()
calls.registerForVoIPPushes()
```

That is the whole setup for the common case: CallWaveKit creates the
`CXProvider` and the `PKPushRegistry`, reports the call, answers it when the
user does, and brings up two-way audio.

Opening the door is one call:

```swift
calls.sendDTMF("1234#") { error in … }
```

Keep a strong reference to the client for its lifetime and inject it into
whatever needs calling features — there is no singleton. Between calls use
`unregister()` or `logout()`; `stop()` destroys the PJSUA runtime and is for
teardown only.

PJSUA has a process-wide C runtime, so only one client may run at a time:
a second `start()` returns `CallWaveErrorEngineAlreadyRunning`.

## Documentation

**[CallWaveKit/README.md](CallWaveKit/README.md)** is the API guide: the
host-owned CallKit/PushKit mode, per-push credentials, the engine and account
settings, call waiting and hold, DTMF, call statistics, the audio-session
hooks, logging, the Swift concurrency layer and the threading contract.

[CHANGELOG.md](CHANGELOG.md) records every release and every breaking change.
[RELEASING.md](RELEASING.md) is the maintainer's checklist for cutting one, and
[FIELD-TESTING.md](FIELD-TESTING.md) is the pass that has to be done by hand on a
device against a real intercom — the unit tests cover none of the answer path,
the push path or the audio session.

[IntercomDemo](Examples/IntercomDemo) shows host-owned CallKit and PushKit.
[COMPATIBILITY.md](COMPATIBILITY.md) lists protocols and toolchains, and
[MIGRATING-FROM-LINPHONE.md](MIGRATING-FROM-LINPHONE.md) maps a Majordom-style
Linphone integration to CallWaveKit.

## What it does

- incoming SIP calls — one by default, call waiting and CallKit hold when the
  engine is configured for more;
- two-way voice through the PJSIP conference bridge, with per-call microphone
  mute at the RTP capture connection;
- answer, decline, hangup, mute and hold through CallKit;
- DTMF over RFC 2833 with a SIP INFO fallback, which is how intercom doors
  open;
- UDP, TCP and TLS, with certificate verification on by default; optional SRTP,
  outbound proxy, separate digest user, custom REGISTER headers, STUN/ICE,
  TURN over UDP/TCP/TLS and codec priorities;
- IPv4, IPv6 and NAT64 connectivity, with an IPv4-only compatibility mode for
  old intercoms;
- a configurable settle delay before `200 OK`, for PBXs that are not ready to
  be answered the moment they send the INVITE, and a ring timeout that rejects
  an unanswered call with `480`;
- SIP account replacement without recreating the PJSUA runtime, for credentials
  that arrive with every push;
- PushKit wake-up handling with a correctly sequenced completion handler and a
  deadline, so the handler always runs and the process is never killed with
  `0xBAADCA11`;
- recovery from Wi-Fi/cellular handovers through `pjsua_handle_ip_change()`;
- audio interruption, media-service reset and wired/Bluetooth route handling;
- per-call RTP/RTCP statistics: packet loss, jitter, round-trip time, codec;
- credential-free diagnostic snapshots for support attachments;
- `os_log` logging with identifier redaction on by default, a sink for the
  host's own stack, and no PJSIP protocol trace in release builds;
- a Swift concurrency layer: an `AsyncStream` of events and `async throws` call
  actions;
- an optional host-owned mode in which the application keeps its own
  `CXProvider` and `PKPushRegistry`.

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

## Rebuilding PJSIP

The checked-in binary can be reproduced with:

```sh
./Scripts/build-pjsip-xcframework.sh
```

The script builds PJSIP 2.17 for iOS 15.0 or later. Override `PJSIP_VERSION`,
`MIN_IOS_VERSION` or `BUILD_JOBS` when necessary.

The checked-in `PJSIP.xcframework` matches the package's own floor: every slice
reports `minos 15.0`, so an application with a 15.x deployment target links it
without `built for newer 'iOS' version` warnings. If you rebuild it, keep the
floor in step with `Package.swift` and the podspec, and check the result on
every slice rather than the first one:

```sh
for a in Vendor/PJSIP.xcframework/*/libPJSIP.a; do
  for arch in $(lipo -archs "$a"); do
    echo "$a $arch $(otool -arch "$arch" -l "$a" | grep -A3 LC_BUILD_VERSION | grep minos | sort -u)"
  done
done
```

The source XCFramework is retained for reproducible development and CocoaPods.
SwiftPM releases use an immutable binary asset so package consumers do not
download the 21 MB framework through Git history. To package a rebuilt binary:

```sh
./Scripts/package-pjsip-release.sh 0.6.0
```

The script prints the archive checksum and the `.binaryTarget(url:checksum:)`
snippet. Release assets include the PJSIP build manifest, GPLv2 copy and all
bundled third-party licences.

## License

CallWaveKit source is MIT — see [LICENSE](LICENSE). The bundled PJSIP binary is
GPL-2.0-or-later or requires a separately arranged proprietary licence. See
[LICENSING.md](LICENSING.md) for the component-by-component terms.
