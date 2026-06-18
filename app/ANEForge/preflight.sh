#!/bin/bash
# Pré-flight déploiement Ember — vérifie que TOUT est prêt avant de packager / notariser.
# Usage :  ./preflight.sh           (après un  DIST=1 ./build_app.sh)
cd "$(dirname "$0")"
FAIL=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "  ✅ $1"; else echo "  ❌ $1"; FAIL=$((FAIL+1)); fi; }

echo "▸ Prérequis du build standalone"
chk "Python relocatable présent" '[ -x "$HOME/.ember-engine-dist/python/bin/python3" ]'
for m in mlx-community--Qwen2.5-1.5B-Instruct-4bit prince-canuma--Kokoro-82M minishlab--potion-multilingual-128M; do
  chk "modèle en cache : $m" "[ -d \"$HOME/.cache/huggingface/hub/models--$m\" ]"
done

echo "▸ Certificat Developer ID (uniquement pour NOTARISER — pas pour la beta non signée)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "  ✅ « Developer ID Application » présent"
else
  echo "  ⚠️  aucun « Developer ID Application » — requis pour notariser (compte Apple Developer 99 \$/an)"
fi

echo "▸ Bundle Ember.app (lance d'abord : DIST=1 ./build_app.sh)"
if [ -d Ember.app ]; then
  PY=$(ls Ember.app/Contents/Resources/engine/python/bin/python3* 2>/dev/null | head -1)
  chk "modèles embarqués (hfcache offline)" '[ -d Ember.app/Contents/Resources/engine/hfcache/hub ]'
  chk "python3 relocatable embarqué"        "[ -n \"$PY\" ]"
  chk "Ember.bin signé hardened runtime"    'codesign -d --verbose=2 Ember.app/Contents/MacOS/Ember.bin 2>&1 | grep -q runtime'
  chk "entitlements sur Ember.bin"          'codesign -d --entitlements - Ember.app/Contents/MacOS/Ember.bin 2>/dev/null | grep -q disable-library-validation'
  chk "python3 signé hardened runtime"      "codesign -d --verbose=2 \"$PY\" 2>&1 | grep -q runtime"
  chk "signature valide (verify strict)"    'codesign --verify --strict Ember.app'
  chk "Ember.entitlements présent"          '[ -f Ember.entitlements ]'
else
  echo "  ⚠️  pas de Ember.app — fais  DIST=1 ./build_app.sh  d'abord"; FAIL=$((FAIL+1))
fi

echo
if [ "$FAIL" = 0 ]; then echo "✅ Pré-flight OK."; else echo "❌ $FAIL point(s) à régler."; fi
exit $FAIL
