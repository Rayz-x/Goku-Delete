#!/bin/bash
# Goku Delete uninstaller — stops the agent and removes the app, LaunchAgent, logs and
# the Accessibility entry. Your files are not touched.
set -uo pipefail
BUNDLE_ID="${BUNDLE_ID:-com.github.rayzx.gokudelete}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/GokuDelete.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only." >&2; exit 1; }
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x GokuDelete 2>/dev/null || true
rm -f "$PLIST"
if [ -d "$APP" ]; then
  if [ -w "$INSTALL_DIR" ]; then rm -rf "$APP"; else sudo rm -rf "$APP"; fi
fi
rm -f "$HOME/Library/Logs/GokuDelete.log" "$HOME/Library/Logs/GokuDelete.err.log"
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || \
  echo "Note: remove GokuDelete from System Settings > Privacy & Security > Accessibility with the minus button."
echo "Goku Delete removed."
