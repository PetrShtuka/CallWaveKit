# Compatibility

| Area | CallWaveKit 0.4 |
| --- | --- |
| iOS | 15.0 or later |
| Swift tools | 5.9 or later |
| Xcode used for release builds | 26.3 |
| PJSIP | 2.17 |
| SIP signalling | UDP, TCP, TLS 1.2+ |
| TLS backend | Apple Network.framework |
| Media encryption | RTP, optional or mandatory SRTP |
| NAT traversal | ICE, STUN, TURN over UDP/TCP/TLS |
| Address families | automatic IPv4/IPv6/NAT64, IPv4-only, IPv6-only |
| Audio | incoming calls, mute, hold, speaker, Bluetooth and wired routes |
| Video | host-owned; Majordom keeps RTSP/VLCKit outside CallWaveKit |

The XCFramework contains `arm64` for iPhone and `arm64` plus `x86_64` for the
Simulator. `Scripts/verify-pjsip-xcframework.sh` checks these slices, the iOS 15
floor and the TLS symbol before CI runs unit tests.
