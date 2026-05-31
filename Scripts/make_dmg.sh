#!/usr/bin/env bash
#
# Build (or reuse) the Release Burnbar.app and wrap it in a drag-to-install DMG.
#
#   ./Scripts/make_dmg.sh   ->   dist/Burnbar-vX.Y.Z.dmg
#
# The DMG contains the ad-hoc-signed Burnbar.app next to an /Applications
# symlink, so the install is the conventional "drag Burnbar onto Applications".
#
# Two code paths, same Definition of Done ("DMG mounts; drag install works"):
#
#   1. Preferred: `create-dmg` (brew install create-dmg) builds a styled window
#      with a background and an --app-drop-link to /Applications.
#   2. Fallback: `create-dmg` styles the window via Finder AppleScript, which
#      fails in a headless/agent environment (no logged-in Finder). If that
#      cosmetic step errors out, we fall back to a plain `hdiutil create` DMG
#      that still ships Burnbar.app + an /Applications symlink — drag-install
#      works, just without the fancy background.
#
# Signing matches package_app.sh and is automatic by environment (#167): with
# DEVELOPER_ID_APPLICATION set, a freshly built app is Developer-ID-signed with
# hardened runtime; if notary credentials are also present the finished DMG is
# notarized + stapled so it opens through the normal Gatekeeper flow. Without
# those env vars it falls back to ad-hoc signing (no hardened runtime, no
# notarization) — Gatekeeper quarantines downloads, users right-click -> Open
# the first time. See README. When the app is REUSED from a prior Release build
# (e.g. package_app.sh already ran), its existing signature is preserved.
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
}

BUILD_DIR="$(pwd)/build"
APP="$BUILD_DIR/Build/Products/Release/Burnbar.app"

# Reuse an existing Release build if present (e.g. from package_app.sh); only
# build when there is nothing to package, to keep DMG packaging fast and to
# preserve the signature 1.6.1 applied.
if [ -d "$APP" ]; then
  echo "==> Reusing existing Release build at $APP"
else
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

  [ -d "$APP" ] || {
    echo "error: build did not produce $APP" >&2
    exit 1
  }

  # Strip extended attributes / resource forks *before* signing so the seal is
  # computed over the clean bundle — same as package_app.sh (#171). Matters when
  # make_dmg.sh builds the app itself (e.g. it runs before package_app.sh in CI)
  # so the DMG-shipped bundle gets the same clean seal as the zip-shipped one.
  echo "==> Stripping extended attributes (clean seal)"
  xattr -cr "$APP"

  if "$(pwd)/Scripts/sign_and_notarize.sh" can-sign; then
    # Developer ID path (#167): hardened-runtime signing of the framework + app.
    "$(pwd)/Scripts/sign_and_notarize.sh" sign-app "$APP"
  else
    echo "==> Ad-hoc signing (--deep covers the embedded BurnbarCore.framework)"
    echo "    (set DEVELOPER_ID_APPLICATION for hardened-runtime Developer ID signing)"
    codesign --force --deep --sign - "$APP"
    codesign --verify --verbose=2 "$APP"
  fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> Version $VERSION"

mkdir -p dist
DMG="dist/Burnbar-v$VERSION.dmg"
rm -f "$DMG"

# Stage just the .app in a clean directory so neither create-dmg nor hdiutil
# picks up anything else from dist/.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Burnbar.app"

build_with_hdiutil() {
  # Plain DMG: Burnbar.app + an /Applications symlink, no window styling.
  ln -snf /Applications "$STAGE/Applications"
  echo "==> Building plain DMG with hdiutil"
  hdiutil create \
    -volname "Burnbar" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null
}

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Building styled DMG with create-dmg"
  # create-dmg refuses to overwrite, so the output must not exist yet (handled
  # by the rm above). It returns non-zero if the Finder AppleScript styling
  # step fails (common headless), so guard it and fall back to hdiutil.
  if create-dmg \
    --volname "Burnbar" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "Burnbar.app" 165 200 \
    --app-drop-link 495 200 \
    --hide-extension "Burnbar.app" \
    --no-internet-enable \
    "$DMG" \
    "$STAGE" >/dev/null 2>&1; then
    echo "==> Styled DMG created"
  else
    echo "warning: create-dmg failed (likely headless Finder styling) — falling back to hdiutil" >&2
    rm -f "$DMG"
    build_with_hdiutil
  fi
else
  echo "note: create-dmg not found (brew install create-dmg) — using plain hdiutil DMG"
  build_with_hdiutil
fi

[ -f "$DMG" ] || {
  echo "error: failed to produce $DMG" >&2
  exit 1
}

# Developer ID path (#167): sign the DMG container with the same identity, then
# notarize + staple it so the mounted volume opens through the normal Gatekeeper
# flow. The enclosed .app must already be Developer-ID + hardened-runtime signed
# (done above when this script builds it, or by package_app.sh when reused).
SIGN="$(pwd)/Scripts/sign_and_notarize.sh"
NOTARIZED=0
if "$SIGN" can-sign; then
  echo "==> Developer ID signing the DMG container"
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
  codesign --verify --verbose=2 "$DMG"
  if "$SIGN" can-notarize; then
    "$SIGN" notarize "$DMG"   # submits, staples, and validates the .dmg
    NOTARIZED=1
  fi
fi

echo ""
echo "Artifact: $DMG"
echo "SHA-256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
if [ "$NOTARIZED" -eq 1 ]; then
  echo "Install:  open the DMG, drag Burnbar.app onto Applications, then open it —"
  echo "          Developer ID signed + notarized + stapled (normal Gatekeeper flow)."
else
  echo "Install:  open the DMG, drag Burnbar.app onto Applications, then"
  echo "          right-click Burnbar.app -> Open (first launch only; ad-hoc/Gatekeeper)."
fi
