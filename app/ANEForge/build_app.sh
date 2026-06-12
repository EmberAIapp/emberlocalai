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

APP="ANEForge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# The real Swift binary becomes a helper; a launcher shim sets engine env vars
# so a double-click finds the dev engine. (Replace with embedded runtime for release.)
cp .build/release/ANEForge "$APP/Contents/MacOS/ANEForge.bin"
cat > "$APP/Contents/MacOS/ANEForge" <<SHIM
#!/bin/bash
export ANEFORGE_PYTHON="\${ANEFORGE_PYTHON:-$REPO/.venv/bin/python}"
export ANEFORGE_PYTHONPATH="\${ANEFORGE_PYTHONPATH:-$REPO/python}"
exec "\$(dirname "\$0")/ANEForge.bin"
SHIM
chmod +x "$APP/Contents/MacOS/ANEForge" "$APP/Contents/MacOS/ANEForge.bin"

# Ad-hoc sign so Gatekeeper lets it run locally
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Built $APP — double-click it or: open $APP"
