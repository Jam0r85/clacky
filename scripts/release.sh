#!/bin/zsh
# Builds a signed, notarized release and publishes it on GitHub.
#
#   ./scripts/release.sh 1.0.0 "What's new in this version."
#
# Uploads Clacky.dmg (for people downloading it) and Clacky.zip (what the app's built-in updater
# installs). Commit your changes first.
#
# One-off setup on the Mac you release from:
#   - A "Developer ID Application" certificate and its private key in your keychain.
#   - Notary credentials (Apple ID plus an app-specific password from account.apple.com):
#       xcrun notarytool store-credentials <profile-name> --team-id <TEAM_ID>
#     then run this with NOTARY_PROFILE=<profile-name> (defaults to Cores-notary).
#   - The GitHub CLI, signed in: gh auth login
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?Usage: ./scripts/release.sh <version> [notes], e.g. ./scripts/release.sh 1.0.0 \"First release.\"}"
NOTES="${2:-}"
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-Cores-notary}"
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"
APP=build/Clacky.app
DMG=build/Clacky.dmg # same names every release: the README's download link relies on them
ZIP=build/Clacky.zip

step() { print -P "\n%B==> $1%b" }

# MARK: - Checks before anything is changed

IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate in your keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No notary credentials saved as '$PROFILE'. Run: xcrun notarytool store-credentials $PROFILE"; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "gh isn't signed in. Run: $GH auth login"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "Tag $TAG already exists."; exit 1; }

# Submits a file to Apple's notary service, waits, and stops with Apple's log if it's rejected.
notarize() {
  local result id notary_status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  id="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  notary_status="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  if [[ "$notary_status" != "Accepted" ]]; then
    echo "Notarization of $1 came back '$notary_status'. Apple's log:"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    exit 1
  fi
  echo "Notarized $1"
}

# MARK: - Version

step "Setting version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" Resources/Info.plist
git commit -q -m "Release $VERSION" Resources/Info.plist

# MARK: - Build, sign and notarize the app

step "Building and signing with $IDENTITY"
RELEASE=1 SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh
codesign --verify --strict --verbose=1 "$APP"

step "Notarizing the app (usually a minute or two)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP" # attach the ticket so it opens even when the Mac is offline
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP" # re-zip with the ticket attached

# MARK: - Disk image

step "Packaging $DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Clacky.app"
ln -s /Applications "$STAGE/Applications" # drag Clacky onto this to install
rm -f "$DMG"
hdiutil create -quiet -volname "Clacky" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# MARK: - Publish

step "Publishing $TAG on GitHub"
git tag -a "$TAG" -m "Clacky $VERSION"
git push -q origin HEAD "$TAG"
"$GH" release create "$TAG" "$DMG" "$ZIP" --title "Clacky $VERSION" --notes "${NOTES:+$NOTES

}Download **Clacky.dmg**, open it and drag Clacky into Applications. On first launch, allow Input Monitoring when macOS asks. If you already have Clacky 1.1 or later, it updates itself.

Needs macOS 13 or later, on Apple silicon or Intel."

step "Done: $("$GH" release view "$TAG" --json url --jq .url)"
