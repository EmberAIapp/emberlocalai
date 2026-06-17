#!/bin/bash
# Developer-ID sign + notarize Ember.app and Ember.dmg — RUN ONCE YOU HAVE AN APPLE DEVELOPER ACCOUNT.
# Nothing here can be done without your account; set YOUR values as env vars, then run:
#
#   DEV_ID="Developer ID Application: Ton Nom (TEAMID)" \
#   APPLE_ID="toi@icloud.com" TEAM_ID="TEAMID" APP_PWD="xxxx-xxxx-xxxx-xxxx" \
#   ./sign_and_notarize.sh
#
# APP_PWD = an app-specific password (appleid.apple.com → Sécurité → Mots de passe pour app).
# Prereq:  DIST=1 ./build_app.sh   (builds the self-contained Ember.app)
set -e
cd "$(dirname "$0")"
: "${DEV_ID:?Set DEV_ID to your 'Developer ID Application: Name (TEAMID)' certificate}"
APP="Ember.app"; DMG="Ember.dmg"
[ -d "$APP" ] || { echo "Build $APP first:  DIST=1 ./build_app.sh"; exit 1; }

echo "1/5  Signing nested binaries (the embedded relocatable Python) with hardened runtime…"
# The embedded Python ships many mach-O files; each must be signed before the outer app.
find "$APP/Contents/Resources/engine" -type f \
  \( -name '*.dylib' -o -name '*.so' -o -name 'python3*' \) -print0 \
  | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$DEV_ID" {} 2>/dev/null || true

echo "2/5  Signing the app (deep, hardened runtime)…"
codesign --force --deep --options runtime --timestamp --sign "$DEV_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "3/5  Building + signing the DMG…"
bash make_dmg.sh
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$DMG"

echo "4/5  Notarizing (uploads to Apple, waits for the verdict)…"
: "${APPLE_ID:?Set APPLE_ID}"; : "${TEAM_ID:?Set TEAM_ID}"; : "${APP_PWD:?Set APP_PWD (app-specific password)}"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PWD" --wait

echo "5/5  Stapling the notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
echo "✅ Done — $DMG is signed, notarized and stapled. Distribuable sans avertissement Gatekeeper."
