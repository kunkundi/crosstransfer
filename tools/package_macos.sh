#!/usr/bin/env bash
# Package a built release .app. Optional Developer ID and notarization profile:
# CT_SIGN_IDENTITY='Developer ID Application: ...' CT_NOTARY_PROFILE=... tools/package_macos.sh
# No credentials: produce an ad-hoc signed local-test DMG, clearly named.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/app/build/macos/Build/Products/Release/crosstransfer.app}"
test -d "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$ROOT/dist" "$STAGE/image"
ditto "$APP" "$STAGE/image/CrossTransfer.app"
PACKED="$STAGE/image/CrossTransfer.app"
test -f "$PACKED/Contents/Frameworks/libcrosstransfer_native.dylib"
# Reject a universal executable paired with a single-architecture core.
for ARCH in $(lipo -archs "$PACKED/Contents/MacOS/crosstransfer"); do
  lipo "$PACKED/Contents/Frameworks/libcrosstransfer_native.dylib" -verify_arch "$ARCH"
done
mkdir -p "$PACKED/Contents/Resources/legal"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$PACKED/Contents/Resources/legal/"
cp "$ROOT/minirtc/thirdparty/webrtc/LICENSE" "$PACKED/Contents/Resources/legal/WebRTC-LICENSE"
cp "$ROOT/minirtc/thirdparty/webrtc/PATENTS" "$PACKED/Contents/Resources/legal/WebRTC-PATENTS"
IDENTITY="${CT_SIGN_IDENTITY:--}"
if [ -n "${CT_NOTARY_PROFILE:-}" ] && [ "$IDENTITY" = - ]; then
  echo 'Notarization requires CT_SIGN_IDENTITY (Developer ID Application)' >&2; exit 1
fi
SIGN_ARGS=(--force --sign "$IDENTITY")
SUFFIX=local-test
if [ "$IDENTITY" != - ]; then SIGN_ARGS+=(--timestamp --options runtime); SUFFIX=signed; fi
# Sign nested code from the inside out, then the containing bundle.
while IFS= read -r -d '' ITEM; do codesign "${SIGN_ARGS[@]}" "$ITEM"; done \
  < <(find "$PACKED/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0)
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/app/macos/Runner/Release.entitlements" "$PACKED"
codesign --verify --deep --strict "$PACKED"
ln -s /Applications "$STAGE/image/Applications"
DMG="$ROOT/dist/CrossTransfer-${VERSION}-macos-${SUFFIX}.dmg"
hdiutil create -volname CrossTransfer -srcfolder "$STAGE/image" -ov -format UDZO "$DMG"
if [ "$IDENTITY" != - ]; then codesign --sign "$IDENTITY" --timestamp "$DMG"; fi
if [ -n "${CT_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$CT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "$DMG"
