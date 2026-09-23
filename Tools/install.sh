#!/bin/bash
# Build Pano, install it to ~/Applications and verify the widget extension is
# actually running the NEW binary.
# Usage: Tools/install.sh
#
# Three traps with a manual install (all measured):
# 1. xcodebuild also registers the build/ copy with LaunchServices/pluginkit;
#    the same bundle ID visible from two places confuses the widget gallery,
#    so that registration is dropped.
# 2. When the app quits, chronod immediately relaunches the extension from the
#    OLD file. Even after the file is replaced, that process keeps running the
#    deleted binary (different inode), so the refresh button keeps drawing the
#    old layout → kill the extension AFTER copying.
# 3. A newly added Widget kind only shows up in the gallery after a version
#    bump (project.yml → CURRENT_PROJECT_VERSION); this script doesn't bump.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
BUILD_APP="$root/build/Build/Products/Release/Pano.app"
APP="$HOME/Applications/Pano.app"
EXT_BIN="$APP/Contents/PlugIns/PanoWidgets.appex/Contents/MacOS/PanoWidgets"

xcodegen generate >/dev/null
xcodebuild -project Pano.xcodeproj -scheme Pano -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

pluginkit -r "$BUILD_APP/Contents/PlugIns/PanoWidgets.appex" 2>/dev/null || true
"$LSREG" -u "$BUILD_APP" 2>/dev/null || true

pkill -f "Applications/Pano.app" || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD_APP" "$HOME/Applications/"
"$LSREG" -f -R -trusted "$APP"

# After the copy: drop any extension process spawned from the old file and
# chronod's cache.
pkill -f "PanoWidgets.appex" || true
killall chronod 2>/dev/null || true
sleep 3
open "$APP"
sleep 5

want=$(stat -f %i "$EXT_BIN")
fail=0
for pid in $(pgrep -f "PanoWidgets.appex" || true); do
  got=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && /PanoWidgets$/ {print $8}')
  if [ "$got" = "$want" ]; then echo "extension pid $pid: new binary ✓"
  else echo "extension pid $pid: OLD binary (inode $got ≠ $want) ✗"; fail=1; fi
done
echo "pluginkit registrations: $(pluginkit -m -v -A -D 2>/dev/null | grep -c dev.pano) (should be 1)"
echo "version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
exit $fail
