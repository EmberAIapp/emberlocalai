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
| **Mémorisation personnelle** | apprend 5 faits, **les restitue après fermeture/réouverture** (5/5) |
| Entraînement local | LoRA 7 modules, convergence réelle, BLAS/Accelerate (~1 s/pas sur 135M) |
| Inférence réelle | génération greedy + contrôle de répétition |
| CLI complète | `create / learn / ask / chat` de bout en bout |
| App macOS native | SwiftUI, glisser-déposer vos données + chat |
| **Inférence sur le Neural Engine** | modèle complet exécuté sur l'ANE, sortie validée — voir [`crates/ane-sys/verify/`](crates/ane-sys/verify/) |

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

## Inférence sur le Neural Engine

L'export d'un modèle vers l'ANE et son exécution sont documentés et reproductibles
dans [`crates/ane-sys/verify/`](crates/ane-sys/verify/README.md). L'inférence
utilise l'API **publique** CoreML (aucune API privée) ; CoreML répartit
automatiquement le calcul sur le Neural Engine.

## Pourquoi l'ANE

L'ANE est ~80× plus efficace par watt qu'un GPU : le Mac reste froid, silencieux,
la batterie tient, et le GPU reste libre. C'est ce qui rendra possible une IA qui
apprend de vous **en continu, en arrière-plan**, sans que vous le remarquiez.

## Avertissements

- Le chemin d'entraînement sur ANE utilise des **APIs privées Apple** (recherche).
- Projet expérimental. Les performances dépendent du modèle, des données, du hardware.

## Licence

MIT — voir [LICENSE](LICENSE).
