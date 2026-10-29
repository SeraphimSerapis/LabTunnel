#!/usr/bin/env bash
# Builds build/LabTunnel.app (menu bar only).
# Signs with SIGN_IDENTITY if set, else the first "Developer ID Application" or
# "Apple Development" identity in the keychain, else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/LabTunnel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/skill"
cp "$BIN_DIR/LabTunnel" "$APP/Contents/MacOS/LabTunnel"
# The CLI is built as labtunnel-cli because "labtunnel" and "LabTunnel" collide on a
# case-insensitive volume. Inside the bundle they live in different folders.
cp "$BIN_DIR/labtunnel-cli" "$APP/Contents/Helpers/labtunnel"
cp skills/labtunnel/SKILL.md "$APP/Contents/Resources/skill/SKILL.md"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
find_identity() {
  { security find-identity -v -p codesigning | grep -F "$1" || true; } | head -1 | sed -E 's/.*"(.*)".*/\1/'
}
IDENTITY=${SIGN_IDENTITY:-$(find_identity "Developer ID Application")}
IDENTITY=${IDENTITY:-$(find_identity "Apple Development")}
IDENTITY=${IDENTITY:--}

# A secure timestamp (needs network) is required for notarization; ad-hoc can't have one.
TIMESTAMP=--timestamp
[[ $IDENTITY == "-" ]] && TIMESTAMP=--timestamp=none
# Nested code is signed first; signing the app seals it.
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP/Contents/Helpers/labtunnel"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Signed with: ${IDENTITY/#-/ad-hoc}"
echo "Built $APP"
