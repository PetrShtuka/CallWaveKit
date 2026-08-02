#!/usr/bin/env bash
#
# Builds and tests the Swift package on an iOS simulator.
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

echo "==> xcodebuild $ACTION -destination '$destination'"
cd "$ROOT"
xcodebuild "$ACTION" \
    -scheme CallWaveKit \
    -destination "$destination" \
    "$@"
