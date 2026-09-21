#!/usr/bin/env bash
# Build a static XCFramework: device arm64 and simulator arm64/x86_64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-release}"
SIM_ARCHS="${CT_IOS_SIM_ARCHS:-arm64 x86_64}"
DEST="$ROOT/app/ios/native"
mkdir -p "$DEST/headers"
cp core/include/crosstransfer/ct_api.h "$DEST/headers/"
BuildSlice() {
  local sdk="$1" arch="$2" appledev=iphone
  [ "$sdk" != simulator ] || appledev=simulator
  xmake f -p iphoneos -a "$arch" -m "$MODE" --appledev="$appledev" \
    --target_minver=15.0 --ct_native=y --ct_cli=n --ct_tests=n \
    --minirtc_examples=n -o "build/ios-$sdk-$arch" -y
  xmake build -y crosstransfer_native
}
BuildSlice device arm64
SIM_LIBS=()
for arch in $SIM_ARCHS; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported simulator arch: $arch" >&2; exit 1;; esac
  BuildSlice simulator "$arch"
  SIM_LIBS+=("$ROOT/build/ios-simulator-$arch/iphoneos/$arch/$MODE/libcrosstransfer_native.a")
done
mkdir -p "$DEST/simulator"
lipo -create "${SIM_LIBS[@]}" -output "$DEST/simulator/libcrosstransfer_native.a"
# xcodebuild refuses to replace an existing framework.
rm -rf "$DEST/crosstransfer_native.xcframework"
xcodebuild -create-xcframework \
  -library "$ROOT/build/ios-device-arm64/iphoneos/arm64/$MODE/libcrosstransfer_native.a" -headers "$DEST/headers" \
  -library "$DEST/simulator/libcrosstransfer_native.a" -headers "$DEST/headers" \
  -output "$DEST/crosstransfer_native.xcframework"

# Flutter must regenerate CocoaPods slice selection when the framework changes.
touch "$ROOT/app/ios/Podfile"
