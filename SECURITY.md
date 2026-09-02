# Security policy

## Reporting a vulnerability

Send a private report through GitHub Security Advisories for this repository.
Include the affected version, a minimal reproduction and whether the issue can
expose SIP credentials, audio or push metadata. Do not open a public issue for
a credential leak or remote crash.

## Supported versions

The latest tagged minor release receives security fixes. CallWaveKit redacts
identifiers in standard logs and omits SIP URIs, Authorization headers and
TURN credentials from diagnostics. Debug-level PJSIP traces can contain full
SIP messages; do not enable them in App Store or TestFlight builds.

## Bundled PJSIP

The binary is built from the PJSIP 2.17 release plus a fixed, reviewable set of
upstream security backports. Their full commit IDs and the one narrow 2.17 SDP
adaptation live in `Scripts/build-pjsip-xcframework.sh`; every generated binary
records the same list in `Vendor/PJSIP-BUILD.txt`. Do not replace the artifact
with an unpatched stock 2.17 build.

CallWaveKit builds with video disabled and Apple's TLS backend, and it does not
run the PJLIB-UTIL HTTP/telnet clients or act as a SIP proxy that re-serializes
received multipart messages. Direct use of the transitive `PJSIP` module is not
a supported API surface. Review the upstream pjproject advisory list before
every release and rebuild the XCFramework when another applicable fix lands.

## PJSIP licence

The public PJSIP binary is GPL-2.0-or-later. Applications distributing it must
comply with the GPL for the resulting program or obtain an appropriate
alternative licence directly from Teluu. See `LICENSING.md` for the complete
component-level notice.
