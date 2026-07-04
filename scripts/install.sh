#!/usr/bin/env bash
# Build my-island (Release, ad-hoc signed) and install it to /Applications.
# Re-run after pulling changes to update the installed app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Generating Xcode project"
xcodegen generate --spec project.yml

echo "==> Building Release"
# Derived-data path ends in .noindex so Spotlight never indexes the intermediate
# my-island.app copies here — otherwise every build leaves launchable duplicates
# that show up alongside the installed app in Spotlight.
xcodebuild -project MyIsland.xcodeproj -scheme MyIsland -configuration Release \
  -derivedDataPath build.noindex \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

APP="build.noindex/Build/Products/Release/my-island.app"

echo "==> Ad-hoc signing"
codesign --force --deep --options runtime --sign - "$APP"

echo "==> Installing to /Applications"
osascript -e 'tell application "my-island" to quit' 2>/dev/null || true
rm -rf /Applications/my-island.app
cp -R "$APP" /Applications/my-island.app

echo "==> Verifying install"
codesign --verify --verbose=1 /Applications/my-island.app 2>&1 | sed 's/^/    /'

echo "==> Cleaning up build artifacts"
rm -rf build.noindex

echo "==> Done. Launch with: open /Applications/my-island.app"
