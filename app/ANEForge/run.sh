#!/bin/bash
# Launch the ANEForge desktop app in dev mode.
# It drives the Python+Rust engine via the `aneforge` CLI, so it needs to know
# where the project venv Python and the `aneforge` package live.
set -e

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export ANEFORGE_PYTHON="${ANEFORGE_PYTHON:-$REPO/.venv/bin/python}"
export ANEFORGE_PYTHONPATH="${ANEFORGE_PYTHONPATH:-$REPO/python}"

echo "Engine python : $ANEFORGE_PYTHON"
echo "Engine path   : $ANEFORGE_PYTHONPATH"
echo "Launching ANEForge…"

cd "$(dirname "$0")"
exec swift run ANEForge
