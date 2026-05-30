#!/usr/bin/env bash
#
# Build Burnbar.app (Debug) and launch it as a menu-bar agent.
# Works from a clean clone — the .xcodeproj is generated from project.yml
# (git-ignored), so we regenerate it first.
#
# Usage: ./Scripts/compile_and_run.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Burnbar.xcodeproj from project.yml"
xcodegen generate

DERIVED="$(pwd)/build/DerivedData"
echo "==> Building Burnbar (Debug)"
xcodebuild build \
  -project Burnbar.xcodeproj \
  -scheme Burnbar \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' || true

APP="$DERIVED/Build/Products/Debug/Burnbar.app"
if [ ! -d "$APP" ]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

echo "==> Launching $APP"
open "$APP"
echo "Burnbar launched — look for the 🔥 flame icon in your menu bar (no Dock icon; it's an LSUIElement agent)."
