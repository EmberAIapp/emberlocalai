# Déploiement Ember (macOS, Apple Silicon)

Deux chemins. **A = beta sans compte Apple (maintenant).** **B = lancement notarisé (plus tard).**

Prérequis communs : les 3 modèles doivent être en cache **avant** le build, sinon l'offline
n'est pas embarqué :
- `mlx-community/Qwen2.5-1.5B-Instruct-4bit`, `prince-canuma/Kokoro-82M`, `minishlab/potion-multilingual-128M`
- (déjà présents dans `~/.cache/huggingface/hub/`).

Le DMG fait **~3 Go** (Python relocatable + 3 modèles embarqués) → **à héberger sur Cloudflare R2**, pas sur Pages (limite 25 Mo/fichier). Egress R2 gratuit via domaine perso.

---

## A) Beta — DMG NON signé (gratuit, immédiat)

```bash
cd app/ANEForge
DIST=1 ./build_app.sh          # build standalone (Python relocatable + modèles, offline)
bash make_dmg.sh               # produit Ember.dmg
```
Puis :
1. **Uploader `Ember.dmg`** dans un bucket **Cloudflare R2**, exposé via un domaine perso.
2. **Site** (`site/index.html`) sur **Cloudflare Pages**, bouton « Télécharger » → l'URL R2.
3. **Indiquer l'install** sur la page (sinon Gatekeeper effraie) :
   > 1ʳᵉ ouverture : **clic-droit → Ouvrir**, ou *Réglages système → Confidentialité et sécurité → « Ouvrir quand même »*. C'est normal : l'app n'est pas encore notarisée Apple — et tout reste 100% local.

L'utilisateur verra **un** avertissement Gatekeeper la 1ʳᵉ fois, puis plus rien.

---

## B) Lancement — DMG signé + notarisé (compte Apple Developer, 99 $/an)

> La création du compte + le paiement = **toi**. Tout le reste (entitlements, script) est prêt.

```bash
cd app/ANEForge
DIST=1 ./build_app.sh
./preflight.sh                 # vérifie modèles, cert, hardened runtime, entitlements
DEV_ID="Developer ID Application: Ton Nom (TEAMID)" \
APPLE_ID="toi@icloud.com" TEAM_ID="TEAMID" APP_PWD="xxxx-xxxx-xxxx-xxxx" \
  ./sign_and_notarize.sh       # signe (inside-out, hardened + entitlements), notarise, staple
```
`APP_PWD` = mot de passe pour app (appleid.apple.com → Sécurité). Puis héberger `Ember.dmg` (R2).
**Vérifier sur un 2ᵉ Mac propre** : le DMG s'ouvre sans avertissement, le chat + le micro marchent.

---

## Déjà vérifié (sans compte)
- Le build standalone signé **hardened runtime + entitlements** lance Python/MLX et **infère** (testé : `/health` ready + chat). Donc la notarisation ne devrait poser aucun problème runtime — il ne reste que la signature Dev-ID + le passage notary (déterministes).
- À surveiller à la notarisation : l'exécutable principal du bundle est un **shim shell** qui exec `Ember.bin` (lui signé hardened). Si `notarytool` s'en plaint, faire de `Ember.bin` l'exécutable principal et porter l'env ailleurs.

## Côté utilisateur au 1er lancement (voix)
Autoriser **Microphone** + **Reconnaissance vocale** quand macOS le demande, puis tester un tour vocal et « Ok Ember ».
