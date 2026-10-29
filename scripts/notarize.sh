#!/usr/bin/env bash
# Notarizes build/LabTunnel.app with Apple and staples the ticket.
# One-time setup, using an App Store Connect API key:
#   xcrun notarytool store-credentials labtunnel --key <AuthKey.p8> --key-id <ID> --issuer <ISSUER>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-labtunnel}
APP=build/LabTunnel.app
ZIP=build/LabTunnel.zip

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl -a -vv -t exec "$APP"
