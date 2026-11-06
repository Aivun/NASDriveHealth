#!/bin/bash
# One-shot build for NAS Drive Health: detects Team ID, generates the Xcode project,
# builds a Release app, installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

step "Checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Full Xcode is required (not just Command Line Tools). Install it from the App Store, open it once, then run:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
xcodebuild -version | head -1

step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install it from https://brew.sh then re-run."
  brew install xcodegen
fi

step "Finding your Apple Development Team ID"
TEAM="${TEAM_ID:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
if [ -z "$TEAM" ]; then
  fail "No 'Apple Development' signing certificate found.
  Open Xcode → Settings → Accounts, add your Apple ID, select your team and click 'Manage Certificates…' → '+' → Apple Development.
  Then re-run this script (or run: TEAM_ID=XXXXXXXXXX bash build.sh)."
fi
echo "Team ID: $TEAM"
sed -i '' "s/^\(    DEVELOPMENT_TEAM: \).*/\1\"$TEAM\"/" project.yml

step "Generating Xcode project"
xcodegen generate

step "Building (Release)"
rm -rf build
set +e
xcodebuild -project NASDriveHealth.xcodeproj -scheme NASDriveHealth -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -destination 'platform=macOS' \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" build \
  2>&1 | tee build.log | grep -E "error:|warning: .*(deprecated|unused)|BUILD (SUCCEEDED|FAILED)|\*\* "
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || fail "Build failed — full log in $(pwd)/build.log"

step "Installing to ~/Applications"
APP="build/Build/Products/Release/NAS Drive Health.app"
mkdir -p "$HOME/Applications"
pkill -x "NAS Drive Health" 2>/dev/null || true
rm -rf "$HOME/Applications/NAS Drive Health.app"
cp -R "$APP" "$HOME/Applications/"
INSTALLED="$HOME/Applications/NAS Drive Health.app"

step "Refreshing macOS widget registration"
# Only the installed copy should be known to macOS, not the one in the build folder.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$APP" >/dev/null 2>&1 || true
rm -rf build/Build/Products
"$LSREG" -f "$INSTALLED" >/dev/null 2>&1 || true
pluginkit -a "$INSTALLED/Contents/PlugIns/DriveHealthWidget.appex" 2>/dev/null || true
# The widget daemon caches the widget list; it restarts by itself.
killall chronod 2>/dev/null || true

open "$INSTALLED"

printf '\n\033[1;32mDone!\033[0m Look for the drive icon in the menu bar → Set up…\n'
printf 'Widgets: right-click the desktop → Edit Widgets… → search "NAS" (Drive Health and Virtual Machines).\n'
