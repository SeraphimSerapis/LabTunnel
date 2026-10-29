#!/usr/bin/env bash
# Builds, signs and installs LabTunnel into /Applications (override with DEST=~/Applications),
# then links the CLI into ~/.local/bin and installs the agent skill into ~/.agents/skills.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=${DEST:-/Applications}

./scripts/build-app.sh

# Quit a running copy first so the bundle isn't replaced under it (this also stops its tunnels).
pkill -x LabTunnel 2>/dev/null && sleep 1 || true

rm -rf "$DEST/LabTunnel.app"
ditto build/LabTunnel.app "$DEST/LabTunnel.app"
codesign --verify --strict "$DEST/LabTunnel.app"
echo "Installed $DEST/LabTunnel.app"

"$DEST/LabTunnel.app/Contents/Helpers/labtunnel" setup
