#!/usr/bin/env bash
# Build a Developer ID-signed, notarized, stapled my-island.app and zip it for distribution.
# Run via: op run --env-file=.env.build -- ./scripts/release.sh
# Requires env: APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD  (injected by op run)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="VTWHBCCP36"
ENT="Sources/App/MyIsland.entitlements"

echo "==> Requiring a Developer ID Application identity (no ad-hoc fallback for releases)"
SIGN_ID="$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [[ -z "$SIGN_ID" ]]; then
  echo "ERROR: no Developer ID Application identity in keychain (was it pruned?)." >&2
  exit 1
fi
echo "    signing as: $SIGN_ID"

echo "==> Generating Xcode project"
xcodegen generate --spec project.yml >/dev/null

# Opening the project in Xcode.app builds it into Xcode's own DerivedData, whose
# my-island.app copies Spotlight does index, so they are cleared before every build.
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/MyIsland-*

echo "==> Building Release"
xcodebuild -project MyIsland.xcodeproj -scheme MyIsland -configuration Release \
  -derivedDataPath build.noindex \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

APP="build.noindex/Build/Products/Release/my-island.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "    built my-island.app $VERSION"

echo "==> Signing inner-to-outer with hardened runtime + secure timestamp"
# 1) Nested Mach-O dylibs (e.g. vendored MediaRemote adapter) — resources aren't signed by the build.
while IFS= read -r -d '' f; do
  echo "    dylib: ${f#$APP/}"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$f"
done < <(find "$APP" -type f -name '*.dylib' -print0)
# 2) Embedded frameworks (e.g. KeyboardShortcuts).
if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw; do
    echo "    framework: ${fw##*/}"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$fw"
  done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
fi
# 3) The app bundle last, carrying the entitlements.
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN_ID" "$APP"

echo "==> Verifying signature (strict)"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|Timestamp' | head

echo "==> Zipping for notarization"
mkdir -p dist
SUBMIT_ZIP="dist/my-island-submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"

echo "==> Final gatekeeper assessment"
xcrun stapler validate "$APP"
spctl -a -vvv -t install "$APP" 2>&1 || true

DIST_ZIP="dist/my-island-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$DIST_ZIP"
rm -f "$SUBMIT_ZIP"
echo "==> Done: $DIST_ZIP"
