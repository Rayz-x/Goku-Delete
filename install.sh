#!/bin/bash
# Goku Delete installer — builds from source, ad-hoc signs, installs to /Applications,
# and starts a per-user LaunchAgent so Goku watches your Finder deletes.
#
#   git clone https://github.com/Rayz-x/Goku-Delete.git && cd Goku-Delete && ./install.sh
#
# Options (environment variables):
#   BUNDLE_ID=com.example.gokudelete   bundle id / LaunchAgent label (default below)
#   INSTALL_DIR=$HOME/Applications     install somewhere other than /Applications
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.github.rayzx.gokudelete}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="GokuDelete.app"
APP="$INSTALL_DIR/$APP_NAME"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/GokuDelete.log"
REPO="$(cd "$(dirname "$0")" && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Preflight -----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "Goku Delete only runs on macOS."
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools are required (they provide swiftc)."
  xcode-select --install 2>/dev/null || true
  die "Finish the Command Line Tools install in the dialog that just opened, then run ./install.sh again."
fi
# /usr/bin/swiftc is Apple's shim; it picks the active developer dir and matching SDK.
SWIFTC="${SWIFTC:-/usr/bin/swiftc}"
"$SWIFTC" --version >/dev/null 2>&1 || die "swiftc isn't working. Try: xcode-select --install  (or sudo xcode-select --reset)"
for f in src/main.swift Resources/Info.plist Resources/goku_charge.png Resources/goku_fire.png; do
  [ -f "$REPO/$f" ] || die "Missing $f — run install.sh from inside the Goku-Delete folder."
done

# 2. Build into a temp folder ------------------------------------------------
BUILD="$(mktemp -d -t gokudelete)"
trap 'rm -rf "$BUILD"' EXIT
STAGE="$BUILD/$APP_NAME"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
say "Compiling with $("$SWIFTC" --version 2>&1 | head -1)"
"$SWIFTC" -O -target "$(uname -m)-apple-macos13.0" \
  -o "$STAGE/Contents/MacOS/GokuDelete" "$REPO/src/main.swift" \
  -framework Cocoa -framework QuartzCore -framework ApplicationServices \
  || die "Compile failed. If it says 'unable to load standard library', run: sudo xcode-select --reset  (then ./install.sh again)"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$REPO/Resources/Info.plist" > "$STAGE/Contents/Info.plist"
cp "$REPO/Resources/goku_charge.png" "$REPO/Resources/goku_fire.png" "$STAGE/Contents/Resources/"
say "Ad-hoc signing ($BUNDLE_ID)"
codesign --force --deep -s - --identifier "$BUNDLE_ID" "$STAGE"
codesign --verify --deep --strict "$STAGE"

# 3. Stop any running copy, then install ------------------------------------------
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x GokuDelete 2>/dev/null || true
SUDO=""
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -w "$INSTALL_DIR" ]; then
  warn "$INSTALL_DIR is not writable; using sudo (you may be asked for your Mac password)."
  SUDO="sudo"
fi
say "Installing to $APP"
$SUDO rm -rf "$APP"
$SUDO ditto "$STAGE" "$APP"
$SUDO xattr -cr "$APP" 2>/dev/null || true
# Make sure LaunchServices knows the app lives here (fixes -10814 / "app at old location").
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

# 4. LaunchAgent ----------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
say "Writing LaunchAgent $PLIST"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/GokuDelete</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/GokuDelete.err.log</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# 5. Accessibility ------------------------------------------------------------------
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
sleep 1
open -R "$APP" 2>/dev/null || true

cat <<MSG

  Goku Delete is installed and running.

  One more step — give it Accessibility permission:
    1. System Settings > Privacy & Security > Accessibility just opened.
    2. If "GokuDelete" is listed, switch it ON.
       If not, click +, pick  $APP  (a Finder window is showing it) and switch it ON.
       Or drag GokuDelete from that Finder window into the list.
    3. Within a few seconds the log shows "event tap installed":
         tail -f "$LOG"

  Test safely:  make a dummy file (touch ~/Desktop/goku-test.txt), select it in Finder,
  press Cmd+Delete. Goku blasts it, then it goes to the Trash (Put Back works).
  Animation only, nothing deleted:  "$APP/Contents/MacOS/GokuDelete" --test

  Uninstall:  ./uninstall.sh
  Rebuilt or re-signed and it stopped working? See Troubleshooting in README.md.
MSG
