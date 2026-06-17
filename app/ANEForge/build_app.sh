#!/bin/bash
# Build a double-clickable ANEForge.app bundle from the SwiftUI executable.
#   ./build_app.sh        -> produces ./ANEForge.app
# The app drives the engine via the `aneforge` CLI; in dev it reads the repo paths
# from a baked-in launcher. A fully self-contained build (embedded Python runtime)
# is the next distribution step — see README.
set -e
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"

echo "Building release binary…"
swift build -c release

APP="Ember.app"
rm -rf "$APP" ANEForge.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# Localizations — copy every <lang>.lproj/Localizable.strings into the app's main
# bundle so SwiftUI's Text(LocalizedStringKey) resolves the user's system language.
if compgen -G "Resources/*.lproj" > /dev/null; then
  cp -R Resources/*.lproj "$APP/Contents/Resources/"
  echo "localizations: $(ls -d Resources/*.lproj | xargs -n1 basename | tr '\n' ' ')"
fi

# The real Swift binary becomes a helper; a launcher shim sets engine env vars
# so a double-click finds the dev engine. (Replace with embedded runtime for release.)
cp .build/release/ANEForge "$APP/Contents/MacOS/Ember.bin"
cat > "$APP/Contents/MacOS/Ember" <<SHIM
#!/bin/bash
export ANEFORGE_PYTHON="\${ANEFORGE_PYTHON:-$HOME/.ember-engine/venv/bin/python}"
export ANEFORGE_PYTHONPATH="\${ANEFORGE_PYTHONPATH:-$HOME/.ember-engine}"
exec "\$(dirname "\$0")/Ember.bin"
SHIM
chmod +x "$APP/Contents/MacOS/Ember" "$APP/Contents/MacOS/Ember.bin"

# App icon: draw the ember, build the .icns
echo "Generating icon…"
swift make_icon.swift /tmp/ember_1024.png >/dev/null 2>&1 || echo "(icon draw skipped)"
if [ -f /tmp/ember_1024.png ]; then
  ICO="Ember.iconset"; rm -rf "$ICO"; mkdir "$ICO"
  for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/ember_1024.png --out "$ICO/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s*2)); sips -z $d $d /tmp/ember_1024.png --out "$ICO/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICO" -o "$APP/Contents/Resources/Ember.icns" 2>/dev/null && echo "icon embedded"
  rm -rf "$ICO"
fi

# Ad-hoc sign so Gatekeeper lets it run locally
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Built $APP — double-click it or: open $APP"
