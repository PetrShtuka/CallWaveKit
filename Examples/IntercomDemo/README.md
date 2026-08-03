# IntercomDemo

This SwiftUI sample keeps CallKit and PushKit in the host, matching Majordom's
integration. CallWaveKit owns SIP registration, INVITE matching, audio and
DTMF. The sample has no VLCKit dependency; an RTSP preview belongs in the host
application.

## Run

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and enter
   test credentials. Git ignores the copied file.
3. Set your development team and bundle identifier in `project.yml`.
4. Run `xcodegen generate`, open `IntercomDemo.xcodeproj` and select a physical
   iPhone. PushKit does not work in the Simulator.
5. Upload the VoIP push token printed by your backend integration. A push uses
   `uuid` and `caller` keys. A cancellation push reuses `uuid` and sets
   `cancelled` to `true`.

The UI exposes answer/end through CallKit, speaker, mute, the `#` door digit
and a redacted diagnostics snapshot. Never commit `Secrets.xcconfig`.
