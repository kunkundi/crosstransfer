#!/usr/bin/env bash
# Build the crosstransfer_native shared library with xmake and copy it into the
# Flutter platform folder consumed by the app.
#
#   tools/build_native.sh [macosx|linux|windows] [arm64|x86_64|x64|universal] [release|debug]
#
# Defaults to the host platform / architecture / release. `macosx universal`
# builds both slices and lipo-merges them.
#
# Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

host_plat() {
  case "$(uname -s)" in
    Darwin) echo macosx ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}
host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64) echo x86_64 ;;
    *) uname -m ;;
  esac
}

PLAT="${1:-$(host_plat)}"
ARCH="${2:-$(host_arch)}"
MODE="${3:-release}"

if [ "$PLAT" = macosx ] && [ "$ARCH" = universal ]; then
  "$0" macosx arm64 "$MODE"
  "$0" macosx x86_64 "$MODE"
  DEST="app/macos/native"
  lipo -create "build/macosx/arm64/$MODE/libcrosstransfer_native.dylib" \
               "build/macosx/x86_64/$MODE/libcrosstransfer_native.dylib" \
       -output "$DEST/libcrosstransfer_native.dylib"
  echo "==> universal dylib:"; lipo -info "$DEST/libcrosstransfer_native.dylib"
  exit 0
fi

extra=()
case "$PLAT" in
  macosx) extra+=(--target_minver=12.0) ;;
  windows) if [ "$ARCH" = "x86_64" ]; then ARCH=x64; fi ;;
esac

echo "==> xmake f -p $PLAT -a $ARCH -m $MODE --ct_native=y ${extra[*]:-}"
xmake f -p "$PLAT" -a "$ARCH" -m "$MODE" --ct_native=y -o build "${extra[@]}" -y
xmake build -y crosstransfer_native

OUT="build/$PLAT/$ARCH/$MODE"
case "$PLAT" in
  macosx)
    DEST="app/macos/native"; mkdir -p "$DEST"
    cp -f "$OUT/libcrosstransfer_native.dylib" "$DEST/"
    ;;
  linux)
    DEST="app/linux/native"; mkdir -p "$DEST"
    cp -f "$OUT/libcrosstransfer_native.so" "$DEST/"
    ;;
  windows)
    DEST="app/windows/native"; mkdir -p "$DEST"
    cp -f "$OUT/crosstransfer_native.dll" "$DEST/"
    ;;
  *)
    echo "unsupported platform $PLAT" >&2; exit 1 ;;
esac
echo "==> copied to $DEST"
ls -la "$DEST"
