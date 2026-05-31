#!/usr/bin/env bash
#
# Capture landing-page screenshots of the real Burnbar app (issue #177).
#
# Produces the PNGs the website's "See Burnbar in action" section renders:
#
#     web/site/public/screenshots/menubar.png       status item in the menu bar
#     web/site/public/screenshots/popover.png       popover with usage data
#     web/site/public/screenshots/empty-state.png   popover with no data yet
#     web/site/public/screenshots/settings.png      the Settings window
#
# Usage:
#     ./Scripts/capture_screenshots.sh              # build, launch, capture all
#     ./Scripts/capture_screenshots.sh menubar      # capture a single shot
#     ./Scripts/capture_screenshots.sh --no-build   # skip build; use a running app
#
# ─────────────────────────────────────────────────────────────────────────────
# REQUIRES SCREEN RECORDING PERMISSION
# ─────────────────────────────────────────────────────────────────────────────
# `screencapture` can only grab window/region pixels when the terminal that runs
# this script has Screen Recording permission. Grant it once:
#
#     System Settings → Privacy & Security → Screen Recording
#       → enable for your terminal (Terminal.app / iTerm / VS Code, etc.)
#       → quit and reopen that terminal so the new permission takes effect.
#
# Without it macOS denies the capture ("could not create image from display")
# and you get a black or empty PNG. There is no headless fallback — capturing a
# menu-bar popover needs a real, interactive display.
#
# ─────────────────────────────────────────────────────────────────────────────
# PRIVACY (load-bearing — see CLAUDE.md "Privacy thesis")
# ─────────────────────────────────────────────────────────────────────────────
# These PNGs go on the public website. Burnbar's UI can surface project dir
# names and paths (cwd / git_*) that must NEVER ship. Before capturing:
#   • Use a clean demo machine or a throwaway login, OR
#   • Confirm the popover/Settings show only token counts, models, costs, dates
#     — no real project names, file paths, or git branches.
# Review every PNG by eye before committing. When in doubt, recapture clean.
#
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="web/site/public/screenshots"
DERIVED="$(pwd)/build/DerivedData"
APP="$DERIVED/Build/Products/Debug/Burnbar.app"

DO_BUILD=1
SHOTS=()

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    menubar | popover | empty-state | settings) SHOTS+=("$arg") ;;
    -h | --help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "valid shots: menubar popover empty-state settings (or --no-build)" >&2
      exit 1
      ;;
  esac
done

# Default: capture everything.
if [ "${#SHOTS[@]}" -eq 0 ]; then
  SHOTS=(menubar popover empty-state settings)
fi

if ! command -v screencapture >/dev/null 2>&1; then
  echo "error: screencapture not found — this script only runs on macOS." >&2
  exit 1
fi

# ── Build + launch ───────────────────────────────────────────────────────────
if [ "$DO_BUILD" -eq 1 ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
  fi
  echo "==> Generating Burnbar.xcodeproj from project.yml"
  xcodegen generate
  echo "==> Building Burnbar (Debug)"
  xcodebuild build \
    -project Burnbar.xcodeproj \
    -scheme Burnbar \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    | grep -E 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' || true

  if [ ! -d "$APP" ]; then
    echo "error: build did not produce $APP" >&2
    exit 1
  fi
  echo "==> Launching $APP"
  open "$APP"
  echo "    Waiting for the menu-bar agent to come up..."
  # No foreground sleep tricks needed — a short settle is fine here.
  for _ in 1 2 3 4 5 6; do
    pgrep -x Burnbar >/dev/null 2>&1 && break
    /bin/sleep 0.5 2>/dev/null || true
  done
fi

mkdir -p "$OUT_DIR"

# Interactive capture helper. `screencapture -i` lets the operator drag a region
# or press SPACE then click a window — the right tool for a transient popover and
# a normal window, neither of which has a stable, scriptable frame.
#   -i  interactive (region / SPACE-to-pick-window)
#   -o  omit the window shadow when picking a window (tighter crop)
#   -r  no screenshot-thumbnail flourish; write the file straight out
capture() {
  local name="$1" hint="$2"
  local path="$OUT_DIR/$name.png"
  echo
  echo "──────────────────────────────────────────────────────────────"
  echo "  Capturing: $name.png"
  echo "  $hint"
  echo "  Drag a region, or press SPACE then click the window. ESC cancels."
  echo "──────────────────────────────────────────────────────────────"
  screencapture -i -o -r "$path"
  if [ -s "$path" ]; then
    echo "  ✓ saved $path"
  else
    echo "  ⚠ no image written for $name (cancelled, or Screen Recording" >&2
    echo "    permission is missing — see the header of this script)." >&2
    rm -f "$path"
  fi
}

for shot in "${SHOTS[@]}"; do
  case "$shot" in
    menubar)
      capture menubar \
        "Click the 🔥 Burnbar item in the menu bar (top-right) so it's active, then capture just the menu-bar status item."
      ;;
    popover)
      capture popover \
        "Open the popover (click the menu-bar item) with usage data visible, then capture the popover window."
      ;;
    empty-state)
      capture empty-state \
        "Open the popover on a profile with NO usage yet (the actionable empty state), then capture it."
      ;;
    settings)
      capture settings \
        "Open Settings (popover footer → gear, or the status-item menu), then capture the Settings window."
      ;;
  esac
done

echo
echo "Done. Review every PNG in $OUT_DIR by eye for stray paths/project names"
echo "(privacy), then set HAS_SCREENSHOTS = true in web/site/app/page.tsx."
