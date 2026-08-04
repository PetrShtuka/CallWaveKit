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

## PJSIP licence

The repository bundles PJSIP under GPLv2. A closed-source application needs a
commercial licence from Teluu. Each application team must verify its licence
before distribution.
