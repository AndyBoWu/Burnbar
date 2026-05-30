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

echo "==> Ad-hoc signing (--deep covers the embedded BurnbarCore.framework)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

mkdir -p dist
ZIP="dist/Burnbar-v$VERSION.zip"
rm -f "$ZIP"
echo "==> Packaging -> $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "Artifact: $ZIP"
echo "SHA-256:  $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "Install:  unzip, then right-click Burnbar.app -> Open (first launch only; ad-hoc/Gatekeeper)."
