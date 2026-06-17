#!/bin/bash
# CLI install — copy Ember.app into /Applications (run DIST=1 ./build_app.sh first).
set -e
cd "$(dirname "$0")"
[ -d Ember.app ] || { echo "Build Ember.app first:  DIST=1 ./build_app.sh"; exit 1; }
DEST="/Applications/Ember.app"
echo "Installing Ember → $DEST …"
rm -rf "$DEST"
ditto Ember.app "$DEST"
echo "Done. Launch it:  open '$DEST'   (or from Launchpad / Applications)"
