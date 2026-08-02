#!/usr/bin/env bash
# Build my-island (Release, ad-hoc signed) and install it to /Applications.
# Re-run after pulling changes to update the installed app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Generating Xcode project"
xcodegen generate --spec project.yml

# Opening the project in Xcode.app builds it into Xcode's own DerivedData, whose
# my-island.app copies Spotlight does index, so they are cleared before every build.
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/MyIsland-*

echo "==> Building Release"
# Derived-data path ends in .noindex so Spotlight never indexes the intermediate
# my-island.app copies here — otherwise every build leaves launchable duplicates
# that show up alongside the installed app in Spotlight.
xcodebuild -project MyIsland.xcodeproj -scheme MyIsland -configuration Release \
  -derivedDataPath build.noindex \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

APP="build.noindex/Build/Products/Release/my-island.app"

# Prefer a stable Developer ID identity over ad-hoc. Ad-hoc (`--sign -`) mints a
# fresh cdhash on every build, and TCC keys its grants to that hash — so each
# reinstall silently revoked Calendar/Accessibility access and the app degraded
# to its permission-gate state with no error (four re-grants in one Phase 4 UAT
# session). A real certificate keeps the designated requirement constant across
# rebuilds, so grants persist. Falls back to ad-hoc when no cert is present.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
  echo "==> Signing with stable identity: $SIGN_ID"
else
  SIGN_ID="-"
  echo "==> No Developer ID found — falling back to ad-hoc (TCC grants will reset each build)"
fi

# --entitlements is REQUIRED here: xcodebuild's own signing step already
# attaches Sources/App/MyIsland.entitlements (CODE_SIGN_ENTITLEMENTS in
# project.yml), but this re-sign uses --force, which replaces the signature
# wholesale — omitting --entitlements here would silently strip the
# calendars entitlement that requestFullAccessToEvents() needs, causing TCC
# to synchronously deny access with no prompt (plan 04-02 checkpoint root
# cause: Hardened Runtime + a signature with zero entitlements attached).
codesign --force --deep --options runtime --entitlements Sources/App/MyIsland.entitlements --sign "$SIGN_ID" "$APP"

echo "==> Installing to /Applications"
osascript -e 'tell application "my-island" to quit' 2>/dev/null || true
rm -rf /Applications/my-island.app
cp -R "$APP" /Applications/my-island.app

echo "==> Verifying install"
codesign --verify --verbose=1 /Applications/my-island.app 2>&1 | sed 's/^/    /'

echo "==> Cleaning up build artifacts"
rm -rf build.noindex

echo "==> Done. Launch with: open /Applications/my-island.app"
