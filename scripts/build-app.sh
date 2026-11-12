#!/usr/bin/env bash
# Builds build/Clacky.app (universal: Apple silicon + Intel) and signs it.
#
# Signing: uses $SIGN_IDENTITY if set, otherwise your first "Apple Development"
# certificate, otherwise ad-hoc. A real certificate keeps the Input Monitoring
# permission across rebuilds; with ad-hoc signing macOS may ask again each build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Clacky.app"
ARCHS=(--arch arm64 --arch x86_64)
if [[ "${UNIVERSAL:-1}" == "0" ]]; then ARCHS=(); fi

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Clacky"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clacky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a Resources/Switches "$APP/Contents/Resources/"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $2; exit}')"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP" >/dev/null
  echo "Signed with $(security find-identity -v -p codesigning | grep "$IDENTITY" | head -1 | sed 's/.*"\(.*\)"/\1/')"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (set SIGN_IDENTITY to use a certificate)"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
