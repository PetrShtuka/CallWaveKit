#!/usr/bin/env bash

set -euo pipefail

PJSIP_VERSION="${PJSIP_VERSION:-2.17}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"
BUILD_JOBS="${BUILD_JOBS:-8}"

# PJSIP 2.17 predates the upstream fixes below and no patched stable release
# exists yet. Keep the released base for compatibility, then apply the exact
# maintainer commits instead of building a moving master branch.
PJSIP_SECURITY_COMMITS=(
  acc03b57cef7a7d31b8e1f5b9117437d7e87c591 # Service-Route stack overflow
  a1b707c0c9b0506faf2a8a438b60f11ffd6a6fd9 # SDP a=crypto stack overflow
  d6a0e7f76611c3a6f530ee051e3e7a622bb1748c # SIP header off-by-one
  8d5956afab2ede95ddb199078dc19a8ac0114f3d # HTTP response heap overflow
  628b71638465bacf66e767959e6acbab822eccd6 # telnet CLI history overflow
  082948b0a2ed658229fc6a50e475b411c69b0d2a # forged simple-STUN response
  fd9074547f4740de86548076c36d8d25be51fab3 # malformed RED SDP crash
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="$PROJECT_ROOT/Vendor/PJSIP.xcframework"
LICENSE_PATH="$PROJECT_ROOT/Vendor/PJSIP-COPYING"
THIRD_PARTY_LICENSES_PATH="$PROJECT_ROOT/Vendor/ThirdPartyLicenses"
BUILD_MANIFEST_PATH="$PROJECT_ROOT/Vendor/PJSIP-BUILD.txt"

# A full three-slice build outlasts a single CI step, so the work directory can
# be pinned from outside: completed stages carry `.callwave-built` stamps and a
# re-run picks up where the previous one stopped.
if [[ -n "${PJSIP_WORK_ROOT:-}" ]]; then
  WORK_ROOT="$PJSIP_WORK_ROOT"
  OWNS_WORK_ROOT=0
else
  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/callwave-pjsip.XXXXXX")"
  OWNS_WORK_ROOT=1
fi

cleanup() {
  if [[ "$OWNS_WORK_ROOT" == "1" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

SOURCE_ROOT="$WORK_ROOT/pjproject"
BUILD_ROOT="$WORK_ROOT/build"
ARTIFACT_ROOT="$WORK_ROOT/artifacts"
OPUS_TARBALL="$WORK_ROOT/opus-$OPUS_VERSION.tar.gz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"

if [[ ! -d "$SOURCE_ROOT" ]]; then
  git clone --depth 1 --branch "$PJSIP_VERSION" \
    https://github.com/pjsip/pjproject.git "$SOURCE_ROOT"
fi
SOURCE_COMMIT="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"

# SHA-256 digest authentication without OpenSSL: Apple-TLS builds compile
# sip_auth_client.c in its no-OpenSSL mode, which upstream restricts to MD5.
if [[ ! -f "$SOURCE_ROOT/.callwave-patched" ]]; then
  cp "$PROJECT_ROOT/Patches/callwave-sha256.h" \
    "$SOURCE_ROOT/pjsip/src/pjsip/callwave_sha256.h"
  git -C "$SOURCE_ROOT" apply \
    "$PROJECT_ROOT/Patches/sip-auth-client-sha256.patch"
  touch "$SOURCE_ROOT/.callwave-patched"
fi

# Each upstream security fix is a merge commit. Fetch its two parents and
# apply only the first-parent diff, without creating local commits or requiring
# git user identity. Per-fix stamps make a pinned work directory resumable.
for security_commit in "${PJSIP_SECURITY_COMMITS[@]}"; do
  security_stamp="$SOURCE_ROOT/.callwave-security-$security_commit"
  if [[ -f "$security_stamp" ]]; then
    continue
  fi
  git -C "$SOURCE_ROOT" fetch --quiet --depth 2 origin "$security_commit"
  if git -C "$SOURCE_ROOT" diff "$security_commit^1" "$security_commit" -- \
      | git -C "$SOURCE_ROOT" apply --check -; then
    git -C "$SOURCE_ROOT" diff "$security_commit^1" "$security_commit" -- \
      | git -C "$SOURCE_ROOT" apply -
  elif ! git -C "$SOURCE_ROOT" diff "$security_commit^1" "$security_commit" -- \
      | git -C "$SOURCE_ROOT" apply --reverse --check -; then
    echo "security backport $security_commit does not apply to PJSIP $PJSIP_VERSION" >&2
    exit 1
  fi
  touch "$security_stamp"
done

# GHSA-rfwg-w9gq-9mw2's master-branch patch includes unrelated 2.18 RED
# changes, so this narrow 2.17 adaptation applies the same missing upper-bound
# checks without importing unreleased feature work.
SDP_BOUNDS_PATCH="$PROJECT_ROOT/Patches/pjsip-2.17-sdp-map-bounds.patch"
SDP_BOUNDS_STAMP="$SOURCE_ROOT/.callwave-security-sdp-map-bounds"
if [[ ! -f "$SDP_BOUNDS_STAMP" ]]; then
  git -C "$SOURCE_ROOT" apply "$SDP_BOUNDS_PATCH"
  touch "$SDP_BOUNDS_STAMP"
fi

fetch_opus() {
  if [[ ! -f "$OPUS_TARBALL" ]]; then
    curl -fL --retry 3 -o "$OPUS_TARBALL" "$OPUS_URL"
  fi
}

# Opus is a static-only cross build per slice; pjproject picks it up through
# --with-opus pointing at this prefix.
build_opus_slice() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local minimum_flag="$4"
  local host="$5"
  local prefix="$BUILD_ROOT/opus-$name"
  local source_dir="$BUILD_ROOT/opus-src-$name"
  local sdk_path

  if [[ -f "$prefix/.callwave-built" ]]; then
    return
  fi
  fetch_opus
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  rm -rf "$source_dir"
  mkdir -p "$source_dir" "$prefix"
  tar -xzf "$OPUS_TARBALL" -C "$source_dir" --strip-components 1

  (
    cd "$source_dir"
    CC="$(xcrun --sdk "$sdk" -f clang)" \
    AR="$(xcrun --sdk "$sdk" -f ar)" \
    RANLIB="$(xcrun --sdk "$sdk" -f ranlib)" \
    CFLAGS="-O2 -arch $arch -isysroot $sdk_path $minimum_flag" \
    LDFLAGS="-arch $arch -isysroot $sdk_path $minimum_flag" \
      ./configure \
        --host="$host" \
        --prefix="$prefix" \
        --disable-shared \
        --enable-static \
        --disable-doc \
        --disable-extra-programs
    make -j"$BUILD_JOBS"
    make install
  )
  touch "$prefix/.callwave-built"
}

build_slice() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local minimum_flag="$4"
  local opus_prefix="$BUILD_ROOT/opus-$name"
  local slice_root="$BUILD_ROOT/$name"
  local sdk_path
  local platform_path

  if [[ -f "$slice_root/.callwave-built" ]]; then
    return
  fi
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  platform_path="$(xcrun --sdk "$sdk" --show-sdk-platform-path)"
  rm -rf "$slice_root"
  cp -R "$SOURCE_ROOT" "$slice_root"

  cat > "$slice_root/pjlib/include/pj/config_site.h" <<'CONFIG_SITE'
#define PJ_CONFIG_IPHONE 1
#define PJMEDIA_HAS_VIDEO 0
#define PJ_HAS_IPV6 1
/*
 * PJSIP's Apple backend uses Network.framework and Security.framework. Keep
 * this explicit: configure-iphone otherwise selects deprecated SecureTransport
 * when it happens to be present in the active SDK.
 */
#define PJ_HAS_SSL_SOCK 1
#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE
#include <pj/config_site_sample.h>
CONFIG_SITE

  (
    cd "$slice_root"
    DEVPATH="$platform_path/Developer" \
    IPHONESDK="$sdk_path" \
    ARCH="-arch $arch" \
    MIN_IOS="$minimum_flag" \
    CFLAGS="-O2" \
    LDFLAGS="-O2 -framework Network -framework Security" \
      ./configure-iphone \
        --with-opus="$opus_prefix" \
        --disable-video \
        --disable-openh264 \
        --disable-ffmpeg \
        --disable-v4l2 \
        --disable-libyuv \
        --disable-g7221-codec
    grep -q '^#define PJ_HAS_SSL_SOCK 1' pjlib/include/pj/config_site.h
    grep -q '^#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE' \
      pjlib/include/pj/config_site.h
    grep -q '^#define PJMEDIA_HAS_OPUS_CODEC 1' \
      pjmedia/include/pjmedia-codec/config_auto.h
    for directory in pjlib/build pjlib-util/build pjnath/build third_party/build pjmedia/build pjsip/build; do
      make -C "$directory" dep
    done
    make -j"$BUILD_JOBS" lib
  )
  touch "$slice_root/.callwave-built"
}

combine_slice() {
  local source_root="$1"
  local opus_prefix="$2"
  local suffix="$3"
  local output="$4"

  mkdir -p "$(dirname "$output")"
  xcrun libtool -static -o "$output" \
    "$source_root/pjsip/lib/libpjsua-$suffix.a" \
    "$source_root/pjsip/lib/libpjsip-ua-$suffix.a" \
    "$source_root/pjsip/lib/libpjsip-simple-$suffix.a" \
    "$source_root/pjsip/lib/libpjsip-$suffix.a" \
    "$source_root/pjmedia/lib/libpjmedia-codec-$suffix.a" \
    "$source_root/pjmedia/lib/libpjmedia-videodev-$suffix.a" \
    "$source_root/pjmedia/lib/libpjmedia-audiodev-$suffix.a" \
    "$source_root/pjmedia/lib/libpjmedia-$suffix.a" \
    "$source_root/pjnath/lib/libpjnath-$suffix.a" \
    "$source_root/pjlib-util/lib/libpjlib-util-$suffix.a" \
    "$source_root/third_party/lib/libgsmcodec-$suffix.a" \
    "$source_root/third_party/lib/libilbccodec-$suffix.a" \
    "$source_root/third_party/lib/libresample-$suffix.a" \
    "$source_root/third_party/lib/libspeex-$suffix.a" \
    "$source_root/third_party/lib/libsrtp-$suffix.a" \
    "$source_root/third_party/lib/libwebrtc-$suffix.a" \
    "$source_root/pjlib/lib/libpj-$suffix.a" \
    "$opus_prefix/lib/libopus.a"
}

copy_headers() {
  local source_root="$1"
  local headers_root="$2"

  mkdir -p "$headers_root"
  cp -R "$source_root/pjlib/include/." "$headers_root/"
  cp -R "$source_root/pjlib-util/include/." "$headers_root/"
  cp -R "$source_root/pjmedia/include/." "$headers_root/"
  cp -R "$source_root/pjnath/include/." "$headers_root/"
  cp -R "$source_root/pjsip/include/." "$headers_root/"
  cp "$source_root/pjsip/include/pjsua-lib/pjsua.h" "$headers_root/pjsua.h"

  cat > "$headers_root/module.modulemap" <<'MODULE_MAP'
module PJSIP [system] {
    umbrella header "pjsua.h"
    export *
}
MODULE_MAP
}

mkdir -p "$BUILD_ROOT" "$ARTIFACT_ROOT"

build_opus_slice device-arm64 iphoneos arm64 \
  "-miphoneos-version-min=$MIN_IOS_VERSION" aarch64-apple-darwin
build_opus_slice simulator-arm64 iphonesimulator arm64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION" aarch64-apple-darwin
build_opus_slice simulator-x86_64 iphonesimulator x86_64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION" x86_64-apple-darwin

build_slice device-arm64 iphoneos arm64 \
  "-miphoneos-version-min=$MIN_IOS_VERSION"
build_slice simulator-arm64 iphonesimulator arm64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION"
build_slice simulator-x86_64 iphonesimulator x86_64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION"

combine_slice "$BUILD_ROOT/device-arm64" "$BUILD_ROOT/opus-device-arm64" \
  aarch64-apple-darwin_ios \
  "$ARTIFACT_ROOT/device/libPJSIP.a"
combine_slice "$BUILD_ROOT/simulator-arm64" "$BUILD_ROOT/opus-simulator-arm64" \
  aarch64-apple-darwin_ios \
  "$ARTIFACT_ROOT/simulator-arm64/libPJSIP.a"
combine_slice "$BUILD_ROOT/simulator-x86_64" "$BUILD_ROOT/opus-simulator-x86_64" \
  x86_64-apple-darwin_ios \
  "$ARTIFACT_ROOT/simulator-x86_64/libPJSIP.a"

mkdir -p "$ARTIFACT_ROOT/simulator"
xcrun lipo -create \
  "$ARTIFACT_ROOT/simulator-arm64/libPJSIP.a" \
  "$ARTIFACT_ROOT/simulator-x86_64/libPJSIP.a" \
  -output "$ARTIFACT_ROOT/simulator/libPJSIP.a"

copy_headers "$BUILD_ROOT/device-arm64" "$ARTIFACT_ROOT/device/Headers"
copy_headers "$BUILD_ROOT/simulator-arm64" "$ARTIFACT_ROOT/simulator/Headers"

xcodebuild -create-xcframework \
  -library "$ARTIFACT_ROOT/device/libPJSIP.a" \
  -headers "$ARTIFACT_ROOT/device/Headers" \
  -library "$ARTIFACT_ROOT/simulator/libPJSIP.a" \
  -headers "$ARTIFACT_ROOT/simulator/Headers" \
  -output "$WORK_ROOT/PJSIP.xcframework"

if [[ "$OUTPUT_PATH" != "$PROJECT_ROOT/Vendor/PJSIP.xcframework" ]]; then
  echo "Refusing to replace unexpected output path: $OUTPUT_PATH" >&2
  exit 1
fi

mkdir -p "$PROJECT_ROOT/Vendor"
rm -rf "$OUTPUT_PATH"
cp -R "$WORK_ROOT/PJSIP.xcframework" "$OUTPUT_PATH"
cp "$SOURCE_ROOT/COPYING" "$LICENSE_PATH"
mkdir -p "$THIRD_PARTY_LICENSES_PATH"
cp "$SOURCE_ROOT/third_party/README.txt" \
  "$THIRD_PARTY_LICENSES_PATH/PJSIP-THIRD-PARTY-README.txt"
cp "$SOURCE_ROOT/third_party/gsm/COPYRIGHT" \
  "$THIRD_PARTY_LICENSES_PATH/GSM-COPYRIGHT"
cp "$SOURCE_ROOT/third_party/resample/COPYING" \
  "$THIRD_PARTY_LICENSES_PATH/RESAMPLE-COPYING"
cp "$SOURCE_ROOT/third_party/speex/COPYING" \
  "$THIRD_PARTY_LICENSES_PATH/SPEEX-COPYING"
cp "$SOURCE_ROOT/third_party/srtp/LICENSE" \
  "$THIRD_PARTY_LICENSES_PATH/SRTP-LICENSE"
cp "$SOURCE_ROOT/third_party/webrtc/LICENSE" \
  "$THIRD_PARTY_LICENSES_PATH/WEBRTC-LICENSE"
cp "$SOURCE_ROOT/third_party/webrtc/LICENSE_THIRD_PARTY" \
  "$THIRD_PARTY_LICENSES_PATH/WEBRTC-LICENSE-THIRD-PARTY"
cp "$BUILD_ROOT/opus-src-device-arm64/COPYING" \
  "$THIRD_PARTY_LICENSES_PATH/OPUS-COPYING"
cp "$PROJECT_ROOT/Patches/callwave-sha256.h" \
  "$THIRD_PARTY_LICENSES_PATH/CALLWAVE-SHA256-SOURCE.txt"

cat > "$BUILD_MANIFEST_PATH" <<BUILD_MANIFEST
PJSIP version: $PJSIP_VERSION
PJSIP commit: $SOURCE_COMMIT
PJSIP patches: Patches/sip-auth-client-sha256.patch (SHA-256 digest without OpenSSL)
PJSIP security backports: ${PJSIP_SECURITY_COMMITS[*]}
PJSIP adapted security patch: Patches/pjsip-2.17-sdp-map-bounds.patch (GHSA-rfwg-w9gq-9mw2)
Opus version: $OPUS_VERSION
Minimum iOS: $MIN_IOS_VERSION
Architectures: iphoneos/arm64, iphonesimulator/arm64+x86_64
TLS: PJ_SSL_SOCK_IMP_APPLE (Network.framework), certificate verification enabled by CallWaveKit
IP: IPv4 and IPv6 enabled; CallWaveKit controls account policy and NAT64
Disabled: video, OpenH264, FFmpeg, V4L2, libyuv, G.722.1
Generated by: Scripts/build-pjsip-xcframework.sh
BUILD_MANIFEST

echo "Created $OUTPUT_PATH"
