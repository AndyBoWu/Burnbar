#!/usr/bin/env bash
#
# Install (or remove) a LaunchAgent so Burnbar auto-starts at login.
#
#   ./Scripts/install_launchagent.sh [/path/to/Burnbar.app]   # install (default /Applications/Burnbar.app)
#   ./Scripts/install_launchagent.sh --uninstall              # remove
#
# Uses only our own bundle id (xyz.andybowu.Burnbar) under the user's
# ~/Library/LaunchAgents — never a system-wide or third-party agent.
#
set -euo pipefail

LABEL="xyz.andybowu.Burnbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled: unloaded $LABEL and removed $PLIST"
  exit 0
fi

APP="${1:-/Applications/Burnbar.app}"
BIN="$APP/Contents/MacOS/Burnbar"
if [ ! -x "$BIN" ]; then
  echo "error: Burnbar binary not found at: $BIN" >&2
  echo "Install Burnbar.app to /Applications first, or pass its path:" >&2
  echo "  ./Scripts/install_launchagent.sh /path/to/Burnbar.app" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Menu-bar agent: launch at login, but if the user quits it, stay quit. -->
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null

# Idempotent: unload any existing instance, then (re)load.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed: $PLIST"
echo "Burnbar will now start automatically at login (and started just now)."
echo "Disable with: ./Scripts/install_launchagent.sh --uninstall"
