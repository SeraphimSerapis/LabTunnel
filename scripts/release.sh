#!/usr/bin/env bash
# Builds a notarized release zip of LabTunnel on this Mac. Signing stays local, so the
# Developer ID certificate never leaves your keychain.
#
# Before running:
#   1. Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist, and commit.
#   2. Have a "Developer ID Application" identity in your keychain, and the notarytool profile
#      described in scripts/notarize.sh.
#
# Writes build/LabTunnel-<version>.zip and prints the commands that publish it. It does not
# tag, push or publish anything itself.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "release: $*" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
ZIP="build/LabTunnel-$VERSION.zip"

# The tag has to point at exactly what was built, so build from a clean commit.
HEAD=$(git rev-parse -q --verify HEAD) || fail "the repository has no commits yet"
[[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first, so the release matches a commit"
TAGGED=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
[[ -z $TAGGED || $TAGGED == "$HEAD" ]] \
  || fail "$TAG already exists on another commit. Bump the version in Resources/Info.plist."

IDENTITIES=$(security find-identity -v -p codesigning)
[[ $IDENTITIES == *"Developer ID Application"* ]] \
  || fail "no Developer ID Application identity in the keychain. Notarization requires one."

./scripts/build-app.sh
# build-app.sh falls back to other identities. Catch that before Apple rejects the upload.
SIGNATURE=$(codesign -dvv build/LabTunnel.app 2>&1)
[[ $SIGNATURE == *"Authority=Developer ID Application"* ]] \
  || fail "build/LabTunnel.app is not signed with a Developer ID Application identity. Check SIGN_IDENTITY."

./scripts/notarize.sh

# Zip after stapling, so the ticket travels with the app and Gatekeeper needs no network check.
rm -f "$ZIP"
ditto -c -k --keepParent build/LabTunnel.app "$ZIP"

echo
echo "Built $ZIP from commit ${HEAD:0:7}"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
echo
echo "Publish it with:"
[[ -n $TAGGED ]] || echo "  git tag $TAG"
echo "  git push origin $TAG"
echo "  gh release create $TAG $ZIP --verify-tag --title \"LabTunnel $VERSION\" --generate-notes"
