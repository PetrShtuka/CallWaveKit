#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK="$ROOT/Vendor/PJSIP.xcframework"
EXPECTED_MIN_IOS="${MIN_IOS_VERSION:-15.0}"

if [[ ! -d "$FRAMEWORK" ]]; then
  echo "missing $FRAMEWORK" >&2
  exit 1
fi

device_library="$FRAMEWORK/ios-arm64/libPJSIP.a"
simulator_library="$FRAMEWORK/ios-arm64_x86_64-simulator/libPJSIP.a"

[[ "$(lipo -archs "$device_library")" == "arm64" ]]
simulator_arches="$(lipo -archs "$simulator_library")"
[[ "$simulator_arches" == *arm64* && "$simulator_arches" == *x86_64* ]]

for headers in "$FRAMEWORK"/*/Headers; do
  grep -q '^#define PJ_HAS_SSL_SOCK 1' "$headers/pj/config_site.h"
  grep -q '^#define PJ_HAS_IPV6 1' "$headers/pj/config_site.h"
  grep -q '^#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE' \
    "$headers/pj/config_site.h"
done

for library in "$device_library" "$simulator_library"; do
  for arch in $(lipo -archs "$library"); do
    min_versions="$(otool -arch "$arch" -l "$library" | awk '
      /LC_BUILD_VERSION/ { in_build = 1; next }
      in_build && /minos/ { print $2; in_build = 0 }
    ' | sort -u)"
    if [[ -z "$min_versions" || "$min_versions" != "$EXPECTED_MIN_IOS" ]]; then
      echo "$library ($arch) has minos '$min_versions', expected $EXPECTED_MIN_IOS" >&2
      exit 1
    fi
  done
done

device_symbols="$(nm -gU "$device_library")"
if [[ "$device_symbols" != *" T _pj_ssl_sock_create"* ]]; then
  echo "PJSIP device library does not export pj_ssl_sock_create" >&2
  exit 1
fi
if [[ "$device_symbols" != *" T _opus_encoder_create"* ]]; then
  echo "PJSIP device library does not export the Opus encoder" >&2
  exit 1
fi
if [[ "$device_symbols" != *" T _pjmedia_codec_opus_init"* ]]; then
  echo "PJSIP device library does not export the Opus codec glue" >&2
  exit 1
fi

# The SHA-256 shim from Patches/ is static inside sip_auth_client.c, so it
# shows up as a local symbol rather than an exported one. Match on a captured
# snapshot: piping nm into `grep -q` can hand nm a SIGPIPE and, under
# pipefail, fail the check despite the symbol being present.
device_all_symbols="$(nm "$device_library")"
if [[ "$device_all_symbols" != *"_cw_sha256_init"* ]]; then
  echo "PJSIP device library does not contain the SHA-256 digest patch" >&2
  exit 1
fi

echo "PJSIP XCFramework: architectures, iOS floor, Apple TLS, Opus and SHA-256 verified"
