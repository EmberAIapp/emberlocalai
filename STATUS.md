# ANEForge — État réel du projet

*Document d'honnêteté technique. Ce qui est prouvé, ce qui reste. Daté du 2026-06-12.*

## En une phrase

Un moteur de fine-tuning de LLM **qui apprend vos faits personnels en local et les
restitue après redémarrage**, avec une CLI et une app macOS native — et l'exécution
sur l'Apple Neural Engine **vérifiée sur silicium M5**.

## Prouvé (vérifié, reproductible)

| Capacité | Preuve |
|---|---|
| Entraînement qui converge | loss 10.8 (vide) → 4.7 (vrais poids) → descend ; LoRA 7 modules |
| Inférence réelle | forward pass + greedy + anti-répétition (pas de bruit aléatoire) |
| **Mémorisation personnelle** | 5/5 faits restitués **après save → fermeture → reload** |
| Vitesse CPU | BLAS/Accelerate : 37 s → 1 s par pas (×36) |
| Produit CLI | `aneforge create / learn / ask / chat` de bout en bout |
| App macOS native | SwiftUI, compile et linke ; pont moteur exécuté (récupère le rappel) |
| **Exécution sur l'ANE** | compile+load+evaluate sur M5, 2048/2048 corrects — voir `crates/ane-sys/verify/` |

## Pas encore fait (ingénierie connue, risque existentiel levé)

- **ANE pour l'entraînement** : l'exécution ANE est prouvée sur un graphe jouet ;
  reste à émettre le MIL de nos vraies ops (matmul/attention/FFN) et à gérer le
  rechargement dynamique des poids LoRA + la limite ~119 compiles/process.
  Aujourd'hui le moteur tourne sur **CPU (Accelerate)** — et c'est déjà utilisable.
- **Distribution** : bundle `.app` signé + runtime Python embarqué (l'app pilote
  actuellement la CLI du dépôt en dev).
- **Qualité modèle** : démontré sur SmolLM2 (135M/360M) ; les vrais modèles
  (Llama-3.2-1B gated, Qwen2.5 a des biais d'attention à gérer) restent à valider.

## Architecture

```
SwiftUI app  ──►  CLI (aneforge)  ──►  Python (orchestration, HF)  ──►  Rust (_core, moteur)
                                                                         └──►  ANE / CPU(Accelerate)
```

- **Rust** (`crates/ane-core`) : forward/backward, LoRA, AdamW, BLAS — le moteur.
- **Rust+ObjC** (`crates/ane-sys`) : accès ANE privé. Chemin vérifié dans `verify/`.
- **Python** (`python/aneforge`) : CLI, chargement HF, persistance, chat.
- **Swift** (`app/ANEForge`) : app native.

## Build / Quickstart

```bash
# moteur natif (extension Python via maturin, PAS `cargo build`)
python -m venv .venv && source .venv/bin/activate
pip install maturin huggingface_hub tokenizers safetensors rich typer numpy ml_dtypes
maturin develop --release -m crates/ane-python/Cargo.toml

# produit
PYTHONPATH=python python -m aneforge.cli create moi --base smollm2-135m
PYTHONPATH=python python -m aneforge.cli learn moi --data mes-faits.txt
PYTHONPATH=python python -m aneforge.cli chat moi

# app macOS
./app/ANEForge/run.sh
```
