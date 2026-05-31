#!/usr/bin/env bash
#
# Build Burnbar.app (Release), ad-hoc-sign it, and zip it for distribution.
#
#   ./Scripts/package_app.sh   ->   dist/Burnbar-vX.Y.Z.zip
#
# v0 uses **ad-hoc signing only** (free; `codesign --sign -`). Because ad-hoc
# signatures carry no Team ID, we deliberately do NOT enable the hardened runtime
# here: hardened runtime + ad-hoc + an embedded framework fails library
# validation and the app won't launch. Developer ID signing + hardened runtime +
# notarization is deferred post-MVP (docs/PLAN.md Epic 1.6).
#
# Ad-hoc means Gatekeeper quarantines downloads — users right-click -> Open the
# first time. See README.
#
# Extended attributes / resource forks are stripped (`xattr -cr`) BEFORE signing,
# and the zip is written with `ditto --norsrc --noextattr --noqtn`, so the archive
# carries no AppleDouble `._*` entries. Those entries leak through plain `unzip`
# and break strict signature verification ("sealed resource is missing or
# invalid"). Stripping before signing keeps the seal intact (#171).
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
}

BUILD_DIR="$(pwd)/build"

echo "==> Generating Burnbar.xcodeproj from project.yml"
xcodegen generate >/dev/null

echo "==> Clean Release build"
xcodebuild clean build \
  -project Burnbar.xcodeproj \
  -scheme Burnbar \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' || true

APP="$BUILD_DIR/Build/Products/Release/Burnbar.app"
[ -d "$APP" ] || {
  echo "error: build did not produce $APP" >&2
  exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> Version $VERSION"

# Strip extended attributes / resource forks *before* signing so the seal is
# computed over the clean bundle. Doing this after signing would invalidate the
# CodeResources hashes; doing it before means there's nothing for ditto to spill
# into AppleDouble `._*` companions later (#171).
echo "==> Stripping extended attributes (no AppleDouble in the zip)"
xattr -cr "$APP"

echo "==> Ad-hoc signing (--deep covers the embedded BurnbarCore.framework)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

mkdir -p dist
ZIP="dist/Burnbar-v$VERSION.zip"
rm -f "$ZIP"
echo "==> Packaging -> $ZIP"
# --norsrc/--noextattr/--noqtn keep resource forks, extended attributes, and the
# quarantine flag out of the archive so no AppleDouble `._*` entries are written
# (the bundle was already stripped + signed above) (#171).
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"

echo ""
echo "Artifact: $ZIP"
echo "SHA-256:  $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "Install:  unzip, then right-click Burnbar.app -> Open (first launch only; ad-hoc/Gatekeeper)."
