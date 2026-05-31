#!/usr/bin/env bash
#
# Render landing-page screenshots from the REAL app SwiftUI views (issue #177).
#
# Unlike capture_screenshots.sh, this needs NO Screen Recording permission and no
# `screencapture`: it drives SwiftUI's `ImageRenderer` from a hosted test target
# (BurnbarScreenshotTests), which renders the actual `PopoverContentView`,
# `LeaderboardSettingsView`, and a menu-bar mock — populated with synthetic sample
# data — to PNGs entirely in-process.
#
# Produces, into web/site/public/screenshots/:
#     menubar.png       menu-bar mock (flame + today's spend)
#     popover.png       popover with usage data
#     empty-state.png   popover with no data yet
#     settings.png      the Settings (Leaderboard tab) window
#
# Usage:
#     ./Scripts/render_screenshots.sh
#
# PRIVACY (load-bearing — see CLAUDE.md "Privacy thesis"): the renderer only ever
# uses synthetic token counts + known model ids. No prompts, paths, project names,
# or user identifiers are ever in scope. Still eyeball every PNG before committing.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="web/site/public/screenshots"
SHOTS_DIR="$(mktemp -d -t burnbar-shots)"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Rendering screenshots via ImageRenderer (BurnbarScreenshots scheme)"
BURNBAR_SHOTS_DIR="$SHOTS_DIR" \
  xcodebuild \
    -project Burnbar.xcodeproj \
    -scheme BurnbarScreenshots \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    test

echo "==> Copying PNGs into $OUT_DIR"
mkdir -p "$OUT_DIR"
for name in menubar popover empty-state settings; do
  src="$SHOTS_DIR/$name.png"
  if [[ -f "$src" ]]; then
    cp "$src" "$OUT_DIR/$name.png"
    printf '    %-16s ' "$name.png"
    sips -g pixelWidth -g pixelHeight "$OUT_DIR/$name.png" | awk '/pixel/ {printf "%s ", $2} END {print ""}'
  else
    echo "    MISSING: $name.png (renderer did not produce it)"
  fi
done

echo "==> Done. Review every PNG by eye before committing."
