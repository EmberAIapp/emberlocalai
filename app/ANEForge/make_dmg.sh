#!/bin/bash
# Build a drag-to-install DMG from Ember.app (run DIST=1 ./build_app.sh first).
set -e
cd "$(dirname "$0")"
APP="Ember.app"; DMG="Ember.dmg"; VOL="Ember"
[ -d "$APP" ] || { echo "Build $APP first:  DIST=1 ./build_app.sh"; exit 1; }
rm -f "$DMG"
WORK="$(mktemp -d)"; STAGE="$WORK/$VOL"; mkdir -p "$STAGE"
echo "Staging $APP ($(du -sh "$APP" | cut -f1))…"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
echo "Creating $DMG (compressed — takes a moment)…"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$WORK"
echo "Built $DMG ($(du -sh "$DMG" | cut -f1)) — open it, drag Ember into Applications."
