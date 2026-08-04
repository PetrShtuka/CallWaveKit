# Roadmap

## 0.4 release completed

- The automated unit/runtime suite, device build, strict-concurrency build and
  CocoaPods lint pass.
- Registration and a real incoming call with two-way audio were confirmed on a
  physical iPhone through the Majordom PBX.
- `PJSIP.xcframework.zip`, SHA-256, SwiftPM checksum, build manifest and
  licences are published in the immutable PJSIP 2.17 binary release.
- SwiftPM resolves the release asset rather than the repository-local binary.

## Later

- Add intercom/PBX compatibility reports from real deployments.
- Add opt-in metric exporters built on the credential-free diagnostic model.

Outgoing calls, SIP video, transfer, conferences, recording, chat and presence
stay outside the current scope. Majordom owns RTSP/VLC video.
