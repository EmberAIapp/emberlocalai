# ANEForge

**Votre IA personnelle, entraînée sur votre Mac. 100% locale.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1--M5-black.svg)]()
[![Rust](https://img.shields.io/badge/Rust-2024-orange.svg)](https://www.rust-lang.org/)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org/)

ANEForge crée une IA qui **apprend de vos propres données** et **s'en souvient** —
sans jamais que rien ne quitte votre Mac. Pas de cloud, pas d'abonnement, pas de
GPU à 10 000 $. Et l'inférence tourne sur l'**Apple Neural Engine**.

```bash
aneforge create moi --base smollm2-135m   # créer
aneforge learn  moi --data mes-notes.txt  # apprendre de vos données
aneforge chat   moi                       # discuter
```

## Ce qui marche aujourd'hui (vérifié)

| Capacité | Preuve |
|---|---|
| **Mémoire personnelle éditable** | Ember apprend vos faits, vous les **voyez, corrigez, supprimez** (`aneforge memory / remember / forget`) ; injectés par récupération — marche sur tout modèle |
| Mémorisation par fine-tuning | apprend votre *style* via LoRA, restitué après fermeture/réouverture (5/5) |
| Entraînement local | LoRA 7 modules, convergence réelle, BLAS/Accelerate (~1 s/pas sur 135M) |
| Inférence réelle | génération greedy + contrôle de répétition |
| CLI complète | `create / learn / ask / chat / memory` de bout en bout |
| App macOS native | SwiftUI, glisser-déposer vos données + chat |
| **Exécution Core ML, Neural Engine activé** | modèle complet exécuté via Core ML (`computeUnits=All`, partition auto vers l'ANE), sortie validée vs référence — voir [`crates/ane-sys/verify/`](crates/ane-sys/verify/) |

Détails honnêtes (prouvé vs à venir) : [STATUS.md](STATUS.md).

## Architecture

```
App SwiftUI  ─►  CLI (aneforge)  ─►  Python (orchestration, HF)  ─►  Rust (_core, moteur)
                                                                      └─►  ANE (inférence) / CPU
```

- **Rust** [`crates/ane-core`](crates/ane-core) — forward/backward, LoRA, AdamW, BLAS.
- **Rust + ObjC** [`crates/ane-sys`](crates/ane-sys) — accès Neural Engine (inférence via CoreML public ; training via APIs privées).
- **Python** [`python/aneforge`](python/aneforge) — CLI, HF, persistance, export ANE.
- **Swift** [`app/ANEForge`](app/ANEForge) — l'app native.

## Installation (dev)

```bash
python -m venv .venv && source .venv/bin/activate
pip install maturin huggingface_hub tokenizers safetensors rich typer numpy ml_dtypes
maturin develop --release -m crates/ane-python/Cargo.toml

PYTHONPATH=python python -m aneforge.cli info
```

Prérequis : macOS 14+, Apple Silicon (M1–M5), Python 3.10+, Xcode CLT.

## App macOS

```bash
./app/ANEForge/build_app.sh   # produit ANEForge.app
open app/ANEForge/ANEForge.app
```

## Mémoire personnelle (ce qui rend "il me connaît" réel)

Les *faits* ("mon chien s'appelle Pixel") vivent dans une mémoire locale
**inspectable, éditable, supprimable** — pas dans le réseau. Le LoRA apprend
votre *voix* ; la mémoire retient vos *faits*, et les réinjecte par récupération
dans le contexte. Résultat : Ember sait, et **vous gardez le contrôle**.

```bash
aneforge remember moi "Mon chien s'appelle Pixel"
aneforge memory   moi          # voir tout ce qu'Ember sait de vous
aneforge forget   moi 3        # oublier un fait  (ou --all)
```

## Exécution sur le Neural Engine

L'export d'un modèle et son exécution sont documentés et reproductibles dans
[`crates/ane-sys/verify/`](crates/ane-sys/verify/README.md). L'inférence utilise
l'API **publique** Core ML (aucune API privée) avec `computeUnits = All` : Core ML
est un *scheduler* qui partitionne le graphe sur CPU/GPU/Neural Engine. La
formulation honnête est donc *"exécution Core ML, Neural Engine activé"* — la
preuve de dispatch ANE op-par-op exige un Core ML Performance Report (Xcode).

## Pourquoi l'ANE

L'ANE est ~80× plus efficace par watt qu'un GPU : le Mac reste froid, silencieux,
la batterie tient, et le GPU reste libre. C'est ce qui rendra possible une IA qui
apprend de vous **en continu, en arrière-plan**, sans que vous le remarquiez.

## Avertissements

- Le chemin d'entraînement sur ANE utilise des **APIs privées Apple** (recherche).
- Projet expérimental. Les performances dépendent du modèle, des données, du hardware.

## Licence

MIT — voir [LICENSE](LICENSE).
