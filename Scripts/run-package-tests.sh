#!/usr/bin/env bash
#
# Builds and tests the Swift package on an iOS simulator.
#
# `xcodebuild` picks SIOSP.xcodeproj over Package.swift when both sit in the
# repository root, and there is no flag to say otherwise, so the package is
# staged in a directory of its own first.
#
#   ./Scripts/run-package-tests.sh                 # test on a picked simulator
#   ACTION=build ./Scripts/run-package-tests.sh    # compile only
#   DESTINATION='platform=iOS Simulator,name=iPhone 16' ./Scripts/run-package-tests.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${ACTION:-test}"

pick_destination() {
    if [[ -n "${DESTINATION:-}" ]]; then
        printf '%s' "$DESTINATION"
        return
    fi
    if [[ "$ACTION" == "build" ]]; then
        printf 'generic/platform=iOS Simulator'
        return
    fi

    local name
    name="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
candidates = [d["name"] for runtime in sorted(devices) if "iOS" in runtime
              for d in devices[runtime] if d.get("isAvailable")]
preferred = [n for n in candidates if n.startswith("iPhone")]
print((preferred or candidates or [""])[0])
')"
    if [[ -z "$name" ]]; then
        echo "no available iOS simulator; install one or set DESTINATION" >&2
        exit 1
    fi
    printf 'platform=iOS Simulator,name=%s' "$name"
}

destination="$(pick_destination)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

for entry in Package.swift CallWaveKit CallWaveKitAsync Tests Vendor; do
    ln -s "$ROOT/$entry" "$stage/$entry"
done

echo "==> xcodebuild $ACTION -destination '$destination'"
cd "$stage"
xcodebuild "$ACTION" \
    -scheme CallWaveKit \
    -destination "$destination" \
    -derivedDataPath "$stage/DerivedData" \
    "$@"
