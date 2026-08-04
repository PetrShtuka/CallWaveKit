# Licensing CallWaveKit

The CallWaveKit distribution contains components under separate licences. The
MIT licence for CallWaveKit does not replace or override the licence of the
bundled PJSIP binary or its third-party components.

## CallWaveKit source

The source code, documentation, examples and build scripts authored for
CallWaveKit are available under the MIT License in `LICENSE`. Existing
copyright notices from earlier MIT-licensed work are retained alongside the
CallWaveKit maintainer's copyright.

SPDX identifier: `MIT`.

## PJSIP binary

`Vendor/PJSIP.xcframework` and the checksum-pinned SwiftPM binary release are
built from PJSIP 2.17. They are not covered by the CallWaveKit MIT License.
PJSIP is offered by its authors under GPL version 2 or any later version, or
under a separately arranged proprietary licence.

The public binary distributed with CallWaveKit uses the GPL option. The full
licence text is in `Vendor/PJSIP-COPYING`, build provenance is recorded in
`Vendor/PJSIP-BUILD.txt`, and the upstream terms are documented at
<https://www.pjsip.org/licensing.htm>.

SPDX identifier: `GPL-2.0-or-later`.

Distributing an application linked with this GPL binary requires compliance
with the GPL for the resulting program. An application that cannot comply with
the GPL must obtain an appropriate alternative PJSIP licence directly from
Teluu. Installing CallWaveKit through SwiftPM or CocoaPods does not grant or
transfer a proprietary PJSIP licence.

## Other bundled software

PJSIP includes third-party software under additional terms. The corresponding
notices and licence texts are in `Vendor/ThirdPartyLicenses`. Applications must
also comply with the terms of the components actually enabled in their build.

This document describes the components shipped by this repository. The actual
licence texts and any separately signed commercial agreement control if this
summary conflicts with them.
