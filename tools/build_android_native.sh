#!/usr/bin/env bash
# Build the FFI library for Android. Set CT_ANDROID_ABIS for a smaller dev build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}"
ABIS="${CT_ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64}"
MODE="${1:-release}"
[ -f "$NDK/source.properties" ] || { echo "Install NDK 28.2.13676358, or set ANDROID_NDK_HOME" >&2; exit 1; }
for abi in $ABIS; do
  case "$abi" in arm64-v8a|armeabi-v7a|x86_64) ;; *) echo "Unsupported Android ABI: $abi" >&2; exit 1;; esac
  xmake f --ct_developer="${CT_DEVELOPER_MODE:-n}" --ct_service_host="${CT_SERVICE_HOST:-}" --ct_link_host="${CT_LINK_HOST:-}" -p android -a "$abi" -m "$MODE" --ndk="$NDK" --ndk_sdkver=24 \
    --runtimes=c++_static --ct_native=y --ct_cli=n --ct_tests=n \
    --minirtc_examples=n -o "build/android-$abi" -y
  xmake build -y crosstransfer_native
  dest="$ROOT/app/android/app/src/main/jniLibs/$abi"
  mkdir -p "$dest"
  cp "build/android-$abi/android/$abi/$MODE/libcrosstransfer_native.so" "$dest/"
done
