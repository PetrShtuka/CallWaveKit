#!/usr/bin/env bash
#
# Zips Vendor/PJSIP.xcframework and prints the SPM binary-target snippet for it.
#
# The XCFramework is 21 MB. Keeping it in git means every clone and every CI
# checkout pays for it, so a tagged release should attach the zip instead and
# Package.swift should point at that URL:
#
#   ./Scripts/package-pjsip-release.sh 0.6.0
#   gh release upload 0.6.0 build/PJSIP.xcframework.zip
#
# Then replace the `path:` binary target in Package.swift with the printed
# `url:`/`checksum:` pair. Keep the local `path:` variant on a branch you
# develop the XCFramework on — SwiftPM cannot resolve a URL that is not
# published yet.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
FRAMEWORK="$ROOT/Vendor/PJSIP.xcframework"
OUTPUT_DIR="$ROOT/build"
ARCHIVE="$OUTPUT_DIR/PJSIP.xcframework.zip"

if [[ -z "$VERSION" ]]; then
    echo "usage: $(basename "$0") <release-tag>" >&2
    exit 2
fi
if [[ ! -d "$FRAMEWORK" ]]; then
    echo "missing $FRAMEWORK — run Scripts/build-pjsip-xcframework.sh first" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE"

# `-X` keeps the archive free of extended attributes, so the checksum is
# reproducible across machines.
( cd "$ROOT/Vendor" && zip -q -r -X "$ARCHIVE" PJSIP.xcframework )

CHECKSUM="$(swift package compute-checksum "$ARCHIVE")"
URL="https://github.com/PetrShtuka/CallWaveKit/releases/download/$VERSION/PJSIP.xcframework.zip"

cat <<SNIPPET

$ARCHIVE
$(du -h "$ARCHIVE" | cut -f1) — checksum $CHECKSUM

Package.swift binary target:

        .binaryTarget(
            name: "PJSIP",
            url: "$URL",
            checksum: "$CHECKSUM"
        ),

CocoaPods: attach the same zip and point the podspec at it:

  spec.vendored_frameworks = 'PJSIP.xcframework'
  spec.prepare_command = 'curl -L -o PJSIP.xcframework.zip "$URL" && unzip -q PJSIP.xcframework.zip'

SNIPPET
