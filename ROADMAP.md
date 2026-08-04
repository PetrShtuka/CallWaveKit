# Roadmap

## 0.4 release gate

- Run REGISTER, INVITE, response-code, BYE, DTMF, hold, TLS, SRTP and TURN
  integration tests against SIPp or Asterisk.
- Pass `FIELD-TESTING.md` in Major-ios on a physical iPhone.
- Publish `PJSIP.xcframework.zip`, SHA-256, SwiftPM checksum, build manifest and
  licences in the GitHub release.
- Change the SwiftPM binary target from the repository path to that release
  asset, then run SwiftPM and CocoaPods validation from a clean checkout.

## Later

- Add intercom/PBX compatibility reports from real deployments.
- Add opt-in metric exporters built on the credential-free diagnostic model.

Outgoing calls, SIP video, transfer, conferences, recording, chat and presence
stay outside the current scope. Majordom owns RTSP/VLC video.
