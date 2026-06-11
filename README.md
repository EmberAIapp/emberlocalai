# ANEForge

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1--M5-black.svg)]()
[![Rust](https://img.shields.io/badge/Rust-2024-orange.svg)](https://www.rust-lang.org/)

**L'IA locale, pour tous. Entrainee sur votre Mac.**

ANEForge est le premier outil open source qui permet de fine-tuner et creer des modeles d'IA directement sur l'Apple Neural Engine — le coprocesseur qui dort dans chaque Mac, iPhone et iPad depuis 2020.

## Pourquoi ANEForge ?

| Aujourd'hui | Avec ANEForge |
|-------------|---------------|
| GPU NVIDIA a 10 000$+ | Votre Mac suffit |
| Cloud a 1-10$/heure | 100% local, gratuit |
| Vos donnees sur des serveurs | Vos donnees restent sur votre Mac |
| Config complexe | 3 commandes |

## Quick Start

```bash
pip install aneforge

# Creer votre IA personnelle
aneforge create mon-assistant --base smollm2

# L'entrainer sur vos donnees
aneforge learn mon-assistant --data mes-notes.txt

# Discuter avec elle
aneforge chat mon-assistant
```

## Installation

### Depuis PyPI (recommande)
```bash
pip install aneforge
```

### Depuis les sources (developpeurs)
```bash
git clone https://github.com/votre-user/aneforge.git
cd aneforge
pip install -e ".[dev]"

# Build le moteur natif Rust
maturin develop --release
```

### Prerequis
- macOS 15+ (Sequoia)
- Apple Silicon (M1, M2, M3, M4, M5)
- Python 3.10+
- Xcode Command Line Tools (`xcode-select --install`)

## Utilisation

### Niveau 1 : Novice (zero connaissance ML)

```bash
# Voir votre hardware et les modeles disponibles
aneforge info

# Creer un modele personnel
aneforge create mon-ia --base smollm2

# L'entrainer
aneforge learn mon-ia --data mes-notes.txt

# Discuter
aneforge chat mon-ia

# Entrainer encore (apprentissage incremental)
aneforge learn mon-ia --data nouveaux-textes.txt
```

### Niveau 2 : Intermediaire

```bash
aneforge train Qwen/Qwen2.5-0.5B \
  --data dataset.jsonl \
  --format chat \
  --lora-rank 16 \
  --epochs 3 \
  --output ./mon-modele

# Exporter pour llama.cpp
aneforge export ./mon-modele --format gguf --output model.gguf
```

### Niveau 3 : Expert (API Python)

```python
from aneforge import Trainer, ANEConfig

config = ANEConfig(
    backend="ane",          # "ane", "mlx", "cpu", "auto"
    lora_rank=32,
    seq_len=1024,
    compile_budget=100,
)

trainer = Trainer("meta-llama/Llama-3.2-1B", config=config)
trainer.load_data("data.jsonl", format="chat")
trainer.train(epochs=3, lr=2e-4)
trainer.export("gguf", "model.gguf")
```

## Modele Personnel

Chaque utilisateur peut creer, entrainer et faire evoluer son propre modele :

```python
from aneforge import PersonalModel

# Creer
model = PersonalModel.create("mon-ia", base="smollm2-360m")

# Entrainer incrementalement
model.learn("emails.txt")        # v1
model.learn("notes.txt")         # v2
model.learn("conversations.txt") # v3

# Historique
model.print_info()
```

Votre modele est stocke dans `~/.aneforge/models/`. Vos donnees ne quittent jamais votre Mac.

## Hardware supporte

ANEForge detecte automatiquement votre Mac et configure les parametres optimaux :

| Chip | ANE TOPS | Bande passante | LoRA Rank | Seq Len | Batch |
|------|----------|----------------|-----------|---------|-------|
| M1       | 11   | 68 GB/s   | 8     | 256     | 1     |
| M1 Pro   | 11   | 200 GB/s  | 16    | 512     | 1     |
| M1 Max   | 11   | 400 GB/s  | 16    | 512     | 2     |
| M2       | 15.8 | 100 GB/s  | 16    | 512     | 1     |
| M2 Pro   | 15.8 | 200 GB/s  | 16    | 512     | 2     |
| M2 Max   | 15.8 | 400 GB/s  | 32    | 1024    | 2     |
| M3       | 18   | 100 GB/s  | 16    | 512     | 2     |
| M3 Pro   | 18   | 200 GB/s  | 32    | 1024    | 2     |
| M3 Max   | 18   | 400 GB/s  | 32    | 1024    | 4     |
| M4       | 38   | 120 GB/s  | 32    | 1024    | 2     |
| M4 Pro   | 38   | 273 GB/s  | 32    | 1024    | 4     |
| M4 Max   | 38   | 546 GB/s  | 64    | 2048    | 4     |
| M5       | 38+  | 120 GB/s  | 32    | 1024    | 4     |
| M5 Pro*  | 38+  | 307 GB/s  | 64    | 2048    | 4     |
| M5 Max*  | 38+  | 614 GB/s  | 64    | 2048    | 8     |

*M5 Pro/Max : Fusion Architecture + Neural Accelerators dans chaque coeur GPU

## Modeles supportes

| Modele | Params | Usage |
|--------|--------|-------|
| SmolLM2-135M | 135M | Experimentation rapide |
| SmolLM2-360M | 360M | Assistant leger |
| Qwen2.5-0.5B | 500M | Multilingue, code |
| TinyLlama-1.1B | 1.1B | Chat general |
| Llama-3.2-1B | 1.2B | Performance equilibree |
| Gemma-2-2B | 2.6B | Haute qualite |
| Phi-3-mini | 3.8B | Raisonnement (16GB+) |

## Formats d'export

```bash
# HuggingFace (safetensors)
aneforge export ./output --format safetensors --output model.safetensors

# llama.cpp (GGUF)
aneforge export ./output --format gguf --output model.gguf

# Apple CoreML
aneforge export ./output --format coreml --output model.mlpackage
```

## Architecture

```
Python (aneforge/)
  │  CLI, Trainer, PersonalModel, Chat, Export
  │
  ├── Rust (ane-core/)     via PyO3
  │     Forward/backward pass, LoRA, optimizer, MIL
  │
  ├── Rust (ane-sys/)      via FFI
  │     ANE runtime, IOSurface, hardware detection
  │
  └── ObjC (ane_bridge.m)  via objc_msgSend
        _ANEClient, _ANECompiler, IOSurface
              │
              ▼
        Apple Neural Engine (hardware)
```

## Innovation cle : LoRA sur ANE

Les poids ANE sont "cuits" dans le code MIL compile. Notre solution :

- Poids de base compiles **une seule fois** (statiques)
- Seuls les petits adapteurs LoRA recompilent (rapide)
- Rang 16 sur dim=768 = 24K params vs 590K pour la couche complete

```
y = W_base @ x + scale * B @ A @ x
    ──────────   ──────────────────
    Compile 1x   Recompile/step (petit)
```

## Backends

ANEForge essaie les backends dans l'ordre :

1. **ANE** (Apple Neural Engine) — via APIs privees reverse-engineerees
2. **MLX** (Metal GPU) — via Apple MLX framework (`pip install mlx`)
3. **CPU** — fallback Python/numpy

```bash
# Forcer un backend
aneforge train smollm2 --data data.txt --backend mlx
```

## Tests

```bash
# Tests Python
pytest tests/python/ -v

# Tests Rust
cargo test

# Verification hardware
aneforge info
```

## Avertissements

- ANEForge utilise des **APIs privees Apple** non documentees
- Ces APIs peuvent changer a chaque mise a jour macOS
- Projet experimental destine a la recherche et l'education
- Les performances dependent du modele, des donnees et du hardware

## Licence

MIT — Voir [LICENSE](LICENSE)
