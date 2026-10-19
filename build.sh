#!/bin/bash
# Builds a universal "Major Update Blocker.app" and a distributable .pkg into ./build.
# Optional signing: SIGN_ID="Developer ID Application: ..." PKG_SIGN_ID="Developer ID Installer: ..."
set -euo pipefail
export COPYFILE_DISABLE=1
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
APP_NAME="Major Update Blocker"
OUT="build"
ROOT="$OUT/root"

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$ROOT/Applications" "$ROOT/Library/LaunchAgents" "$ROOT/Library/LaunchDaemons"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12.0" Sources/main.swift -o "$OUT/bin/mub-$arch"
done
APP="$ROOT/Applications/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$OUT"/bin/mub-* -output "$APP/Contents/MacOS/MajorUpdateBlocker"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
xattr -cr "$ROOT"
codesign --force --sign "${SIGN_ID:--}" "$APP"

cp Resources/org.majorupdateblocker.plist "$ROOT/Library/LaunchAgents/"
cp Resources/org.majorupdateblocker.daemon.plist "$ROOT/Library/LaunchDaemons/"
chmod +x scripts/postinstall
xattr -cr "$ROOT"

# Don't let the installer relocate the app if a copy exists elsewhere.
pkgbuild --analyze --root "$ROOT" "$OUT/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$OUT/components.plist"

SIGN_ARGS=()
[ -n "${PKG_SIGN_ID:-}" ] && SIGN_ARGS=(--sign "$PKG_SIGN_ID")

pkgbuild --root "$ROOT" --component-plist "$OUT/components.plist" \
  --identifier org.majorupdateblocker.pkg --version "$VERSION" \
  --scripts scripts --install-location / \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$OUT/MajorUpdateBlocker-$VERSION.pkg"

echo "Built $OUT/MajorUpdateBlocker-$VERSION.pkg"
