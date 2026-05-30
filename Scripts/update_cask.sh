#!/usr/bin/env bash
#
# Bump the Homebrew cask (in the public andybowu/homebrew-tap repo) to a new
# release: updates `version` and `sha256` in Casks/burnbar.rb.
#
# Run AFTER cutting the GitHub Release:
#   ./Scripts/package_app.sh                       # builds dist/Burnbar-vX.Y.Z.zip + prints sha256
#   gh release create vX.Y.Z dist/Burnbar-vX.Y.Z.zip
#   ./Scripts/update_cask.sh X.Y.Z /path/to/homebrew-tap
#
set -euo pipefail

VERSION="${1:-}"
TAP_DIR="${2:-}"
if [ -z "$VERSION" ] || [ -z "$TAP_DIR" ]; then
  echo "usage: $0 <version> <path-to-homebrew-tap-checkout>" >&2
  echo "  e.g. $0 0.1.0 ~/src/homebrew-tap" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
ZIP="dist/Burnbar-v${VERSION}.zip"
[ -f "$ZIP" ] || {
  echo "error: $ZIP not found — run ./Scripts/package_app.sh first" >&2
  exit 1
}

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
CASK="$TAP_DIR/Casks/burnbar.rb"
[ -f "$CASK" ] || {
  echo "error: $CASK not found. First copy Scripts/homebrew/burnbar.rb into the tap repo." >&2
  exit 1
}

# Update version + sha256 in place (BSD sed).
/usr/bin/sed -i '' -E \
  -e "s/version \"[^\"]*\"/version \"${VERSION}\"/" \
  -e "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" \
  "$CASK"

echo "Updated $CASK → version ${VERSION}, sha256 ${SHA}"
echo "Now commit + push the tap repo, then: brew install --cask andybowu/tap/burnbar"
