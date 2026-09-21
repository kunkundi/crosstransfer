#!/usr/bin/env bash
# Package an already built Flutter Linux release bundle on the target machine.
# Usage: tools/package_linux.sh [bundle-directory]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  x86_64) FLUTTER_ARCH=x64; DEB_ARCH=amd64 ;;
  aarch64) FLUTTER_ARCH=arm64; DEB_ARCH=arm64 ;;
  *) echo 'Unsupported Linux architecture' >&2; exit 1 ;;
esac
BUNDLE="${1:-$ROOT/app/build/linux/$FLUTTER_ARCH/release/bundle}"
BUNDLE="$(cd "$BUNDLE" && pwd)"
test -f "$BUNDLE/crosstransfer"
test -f "$BUNDLE/lib/libcrosstransfer_native.so"
for ELF in "$BUNDLE/crosstransfer" "$BUNDLE/lib/libcrosstransfer_native.so"; do
  case "$DEB_ARCH" in
    amd64) readelf -h "$ELF" | grep -q 'Advanced Micro Devices X86-64' ;;
    arm64) readelf -h "$ELF" | grep -q 'AArch64' ;;
  esac
done
VERSION="$(awk '/^version:/ {print $2}' "$ROOT/app/pubspec.yaml")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/pkg/opt/crosstransfer" "$STAGE/pkg/usr/bin" \
  "$STAGE/pkg/usr/share/applications" "$STAGE/pkg/usr/share/icons/hicolor/256x256/apps" \
  "$STAGE/pkg/usr/share/doc/crosstransfer" "$STAGE/pkg/DEBIAN" "$STAGE/debian" "$ROOT/dist"
cp -a "$BUNDLE/." "$STAGE/pkg/opt/crosstransfer/"
ln -s /opt/crosstransfer/crosstransfer "$STAGE/pkg/usr/bin/crosstransfer"
cp "$ROOT/packaging/linux/"*.desktop "$STAGE/pkg/usr/share/applications/"
desktop-file-validate "$STAGE/pkg/usr/share/applications/"*.desktop
cp "$ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" \
  "$STAGE/pkg/usr/share/icons/hicolor/256x256/apps/com.crosstransfer.crosstransfer.png"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/pkg/usr/share/doc/crosstransfer/"
cp "$ROOT/minirtc/thirdparty/webrtc/LICENSE" "$STAGE/pkg/usr/share/doc/crosstransfer/WebRTC-LICENSE"
cp "$ROOT/minirtc/thirdparty/webrtc/PATENTS" "$STAGE/pkg/usr/share/doc/crosstransfer/WebRTC-PATENTS"
# Derive runtime dependencies from every ELF shipped in the bundle, including
# plugins; do not guess the GTK/glibc package names for a distribution.
cat > "$STAGE/debian/control" <<'EOF'
Source: crosstransfer
Section: net
Priority: optional
Maintainer: DI JUNKUN <dijunkun@users.noreply.github.com>

Package: crosstransfer
Architecture: any
Description: P2P file transfer with take-codes
EOF
ELFS=(-e"$BUNDLE/crosstransfer")
while IFS= read -r -d '' LIB; do ELFS+=(-e"$LIB"); done < <(find "$BUNDLE/lib" -name '*.so' -type f -print0)
DEPS="$(cd "$STAGE" && dpkg-shlibdeps --ignore-missing-info -O -l"$BUNDLE/lib" "${ELFS[@]}" | sed -n 's/^shlibs:Depends=//p')"
test -n "$DEPS"
cat > "$STAGE/pkg/DEBIAN/control" <<EOF
Package: crosstransfer
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Maintainer: DI JUNKUN <dijunkun@users.noreply.github.com>
Depends: $DEPS, xdg-utils
Description: P2P file transfer with take-codes
 Transfer files directly between devices using a code or link.
EOF
chmod -R go-w "$STAGE/pkg"
DEB="crosstransfer_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE/pkg" "$ROOT/dist/$DEB"
(cd "$ROOT/dist" && sha256sum "$DEB" > "$DEB.sha256")
