#!/bin/bash
# Build a double-clickable Ember.app from the SwiftUI executable.
#   ./build_app.sh                  -> dev build (embeds the Homebrew-based venv)
#   DIST=1 ./build_app.sh           -> ANY-MAC build: embeds the relocatable Python
#                                      (python-build-standalone) + repo engine + models
#   EMBED_ENGINE=0 ./build_app.sh   -> binary only (uses ~/.ember-engine; fast dev iteration)
# DIST=1 produces a fully self-contained .app (no Homebrew, models offline). The only remaining
# distribution step is Apple Developer-ID signing + notarisation (see sign_and_notarize.sh).
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

# Embed the engine INSIDE the .app (§6: no dependency on the dev folder). Two modes:
#   DIST=1 → embed the RELOCATABLE Python (python-build-standalone, ~/.ember-engine-dist/python)
#            + the repo aneforge → runs on ANY Mac, no Homebrew. (Distribution build.)
#   else   → embed the dev venv (~/.ember-engine/venv) — fast, but depends on Homebrew python.
RELOC="$HOME/.ember-engine-dist/python"
ANEFORGE_SRC="$REPO/python/aneforge"
if [ "${EMBED_ENGINE:-1}" = "1" ]; then
  mkdir -p "$APP/Contents/Resources/engine"
  ditto "$ANEFORGE_SRC" "$APP/Contents/Resources/engine/aneforge"
  if [ "${DIST:-0}" = "1" ] && [ -x "$RELOC/bin/python3" ]; then
    echo "Embedding RELOCATABLE Python ($(du -sh "$RELOC" | cut -f1)) — any-Mac…"
    ditto "$RELOC" "$APP/Contents/Resources/engine/python"
    echo "relocatable python embedded"
  elif [ -d "$HOME/.ember-engine/venv" ]; then
    echo "Embedding dev venv ($(du -sh "$HOME/.ember-engine/venv" | cut -f1))…"
    ditto "$HOME/.ember-engine/venv" "$APP/Contents/Resources/engine/venv"
    echo "venv embedded (Homebrew-based — use DIST=1 for a true any-Mac build)"
  fi
fi

# Embed the Kokoro voice model so Ember's neural voice (Mode Her) works OFFLINE on any Mac.
# The bundled venv already carries mlx-audio + misaki + phonemizer + a bundled espeak-ng
# (espeakng_loader's .dylib) via ditto above; only the model weights live in the HF cache.
KOKORO_SRC="$HOME/.cache/huggingface/hub/models--prince-canuma--Kokoro-82M"
if [ "${EMBED_ENGINE:-1}" = "1" ] && [ -d "$KOKORO_SRC" ]; then
  echo "Embedding Kokoro voice model ($(du -sh "$KOKORO_SRC" | cut -f1))…"
  mkdir -p "$APP/Contents/Resources/engine/hfcache/hub"
  ditto "$KOKORO_SRC" "$APP/Contents/Resources/engine/hfcache/hub/models--prince-canuma--Kokoro-82M"
  echo "voice model embedded"
fi
# Embed the chat model too, so HF_HOME can point at the bundled cache (offline, any-Mac).
# (Both models must live there or redirecting HF_HOME would hide the chat model.)
QWEN_SRC="$HOME/.cache/huggingface/hub/models--mlx-community--Qwen2.5-1.5B-Instruct-4bit"
if [ "${EMBED_ENGINE:-1}" = "1" ] && [ -d "$QWEN_SRC" ]; then
  echo "Embedding chat model ($(du -sh "$QWEN_SRC" | cut -f1))…"
  mkdir -p "$APP/Contents/Resources/engine/hfcache/hub"
  ditto "$QWEN_SRC" "$APP/Contents/Resources/engine/hfcache/hub/models--mlx-community--Qwen2.5-1.5B-Instruct-4bit"
  echo "chat model embedded"
fi
# Embed the multilingual semantic embedder so cross-lingual memory recall works OFFLINE.
EMB_SRC="$HOME/.cache/huggingface/hub/models--minishlab--potion-multilingual-128M"
if [ "${EMBED_ENGINE:-1}" = "1" ] && [ -d "$EMB_SRC" ]; then
  echo "Embedding semantic embedder ($(du -sh "$EMB_SRC" | cut -f1))…"
  mkdir -p "$APP/Contents/Resources/engine/hfcache/hub"
  ditto "$EMB_SRC" "$APP/Contents/Resources/engine/hfcache/hub/models--minishlab--potion-multilingual-128M"
  echo "embedder embedded"
fi

# The real Swift binary becomes a helper; a launcher shim points the engine env vars
# at the EMBEDDED engine first, falling back to the dev folder if not bundled.
cp .build/release/ANEForge "$APP/Contents/MacOS/Ember.bin"
cat > "$APP/Contents/MacOS/Ember" <<'SHIM'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
ENG="$DIR/../Resources/engine"
if [ -x "$ENG/python/bin/python3" ]; then           # relocatable Python (any-Mac DIST build)
  export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$ENG/python/bin/python3}"
  export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$ENG}"
elif [ -x "$ENG/venv/bin/python" ]; then             # dev venv embedded
  export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$ENG/venv/bin/python}"
  export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$ENG}"
else                                                 # dev-folder fallback
  export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$HOME/.ember-engine/venv/bin/python}"
  export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$HOME/.ember-engine}"
fi
# Use the embedded models (offline) when present. In a bundled build the model is shipped,
# so we FORCE offline: no silent Hugging Face download/HEAD at runtime (deploy = 100% local).
if [ -d "$ENG/hfcache" ]; then
  export HF_HOME="${HF_HOME:-$ENG/hfcache}"
  export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
  export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
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
