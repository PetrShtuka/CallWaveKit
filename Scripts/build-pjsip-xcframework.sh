#!/usr/bin/env bash

set -euo pipefail

PJSIP_VERSION="${PJSIP_VERSION:-2.17}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"
BUILD_JOBS="${BUILD_JOBS:-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="$PROJECT_ROOT/Vendor/PJSIP.xcframework"
LICENSE_PATH="$PROJECT_ROOT/Vendor/PJSIP-COPYING"
THIRD_PARTY_LICENSES_PATH="$PROJECT_ROOT/Vendor/ThirdPartyLicenses"
BUILD_MANIFEST_PATH="$PROJECT_ROOT/Vendor/PJSIP-BUILD.txt"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/callwave-pjsip.XXXXXX")"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

SOURCE_ROOT="$WORK_ROOT/pjproject"
BUILD_ROOT="$WORK_ROOT/build"
ARTIFACT_ROOT="$WORK_ROOT/artifacts"

git clone --depth 1 --branch "$PJSIP_VERSION" \
  https://github.com/pjsip/pjproject.git "$SOURCE_ROOT"
SOURCE_COMMIT="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"

build_slice() {
  local name="$1"
  local sdk="$2"
  local arch="$3"
  local minimum_flag="$4"
  local slice_root="$BUILD_ROOT/$name"
  local sdk_path
  local platform_path

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  platform_path="$(xcrun --sdk "$sdk" --show-sdk-platform-path)"
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
        --disable-video \
        --disable-opus \
        --disable-openh264 \
        --disable-ffmpeg \
        --disable-v4l2 \
        --disable-libyuv \
        --disable-g7221-codec
    grep -q '^#define PJ_HAS_SSL_SOCK 1' pjlib/include/pj/config_site.h
    grep -q '^#define PJ_SSL_SOCK_IMP PJ_SSL_SOCK_IMP_APPLE' \
      pjlib/include/pj/config_site.h
    for directory in pjlib/build pjlib-util/build pjnath/build third_party/build pjmedia/build pjsip/build; do
      make -C "$directory" dep
    done
    make -j"$BUILD_JOBS" lib
  )
}

combine_slice() {
  local source_root="$1"
  local suffix="$2"
  local output="$3"

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
    "$source_root/pjlib/lib/libpj-$suffix.a"
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

build_slice device-arm64 iphoneos arm64 \
  "-miphoneos-version-min=$MIN_IOS_VERSION"
build_slice simulator-arm64 iphonesimulator arm64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION"
build_slice simulator-x86_64 iphonesimulator x86_64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION"

combine_slice "$BUILD_ROOT/device-arm64" aarch64-apple-darwin_ios \
  "$ARTIFACT_ROOT/device/libPJSIP.a"
combine_slice "$BUILD_ROOT/simulator-arm64" aarch64-apple-darwin_ios \
  "$ARTIFACT_ROOT/simulator-arm64/libPJSIP.a"
combine_slice "$BUILD_ROOT/simulator-x86_64" x86_64-apple-darwin_ios \
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

cat > "$BUILD_MANIFEST_PATH" <<BUILD_MANIFEST
PJSIP version: $PJSIP_VERSION
PJSIP commit: $SOURCE_COMMIT
Minimum iOS: $MIN_IOS_VERSION
Architectures: iphoneos/arm64, iphonesimulator/arm64+x86_64
TLS: PJ_SSL_SOCK_IMP_APPLE (Network.framework), certificate verification enabled by CallWaveKit
IP: IPv4 and IPv6 enabled; CallWaveKit controls account policy and NAT64
Disabled: video, Opus, OpenH264, FFmpeg, V4L2, libyuv, G.722.1
Generated by: Scripts/build-pjsip-xcframework.sh
BUILD_MANIFEST

echo "Created $OUTPUT_PATH"
