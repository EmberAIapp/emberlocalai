#!/bin/bash
# Build a double-clickable Ember.app from the SwiftUI executable.
#   ./build_app.sh                 -> produces ./Ember.app (engine embedded)
#   EMBED_ENGINE=0 ./build_app.sh  -> skip embedding (faster dev builds; uses ~/.ember-engine)
# The Python venv + aneforge engine are bundled into Contents/Resources/engine so the .app
# does NOT depend on the dev folder (§6) — proven by running with ~/.ember-engine removed.
# Remaining for any-Mac distribution: a relocatable interpreter (python-build-standalone, the
# bundled venv currently uses Homebrew python@3.14) + Apple signing/notarisation.
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

# Embed the engine (Python venv + aneforge) INSIDE the .app so it no longer depends
# on the separate ~/.ember-engine dev folder (§6: "jamais de dépendance à l'environnement
# de dev"). ditto preserves the venv's symlinks. NOTE: the venv's base interpreter is still
# Homebrew python@3.14 — a fully any-Mac build needs an embedded relocatable Python
# (python-build-standalone); that's the remaining distribution step.
ENGSRC="$HOME/.ember-engine"
if [ "${EMBED_ENGINE:-1}" = "1" ] && [ -d "$ENGSRC/venv" ] && [ -d "$ENGSRC/aneforge" ]; then
  echo "Embedding engine ($(du -sh "$ENGSRC" | cut -f1))…"
  mkdir -p "$APP/Contents/Resources/engine"
  ditto "$ENGSRC/aneforge" "$APP/Contents/Resources/engine/aneforge"
  ditto "$ENGSRC/venv"     "$APP/Contents/Resources/engine/venv"
  echo "engine embedded"
fi

# The real Swift binary becomes a helper; a launcher shim points the engine env vars
# at the EMBEDDED engine first, falling back to the dev folder if not bundled.
cp .build/release/ANEForge "$APP/Contents/MacOS/Ember.bin"
cat > "$APP/Contents/MacOS/Ember" <<'SHIM'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
ENG="$DIR/../Resources/engine"
if [ -x "$ENG/venv/bin/python" ]; then
  export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$ENG/venv/bin/python}"
  export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$ENG}"
else
  export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$HOME/.ember-engine/venv/bin/python}"
  export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$HOME/.ember-engine}"
fi
exec "$DIR/Ember.bin"
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
