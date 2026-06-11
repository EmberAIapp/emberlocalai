# ANEForge

## L'IA locale, pour tous. Entrainee sur votre Mac.

ANEForge est le premier outil open source qui permet a n'importe qui de fine-tuner
et creer des modeles d'IA directement sur l'Apple Neural Engine — le coprocesseur
qui dort dans chaque Mac, iPhone et iPad depuis 2020.

---

## Le probleme

Aujourd'hui, fine-tuner un modele d'IA necessite :
- Des GPU NVIDIA a 10 000-40 000$ (A100, H100)
- Des abonnements cloud a 1-10$/heure
- Des connaissances avancees en ML
- L'envoi de vos donnees privees vers des serveurs distants

Pendant ce temps, le Neural Engine de votre Mac tourne au ralenti.
Apple le reserve a l'inference (execution) via CoreML.
Le training ? Interdit. Verrouille. Pas d'API publique.

Jusqu'a maintenant.

## La percee

En 2026, le projet maderix/ANE (MIT, 4000+ stars) a prouve qu'il est possible
d'entrainer des reseaux de neurones directement sur l'ANE en utilisant des APIs
privees reverse-engineerees. Resultat : 1.78 TFLOPS soutenus a 11.2% d'utilisation
seulement, avec une efficacite energetique 80x superieure a un NVIDIA A100.

ANEForge transforme cette percee de recherche en un outil utilisable par tous.

## Ce qu'ANEForge fait

```
pip install aneforge

# Creer votre IA personnelle
aneforge create mon-assistant --base smollm2

# L'entrainer sur vos donnees
aneforge learn mon-assistant --data mes-notes.txt

# Discuter avec elle
aneforge chat mon-assistant
```

C'est tout. Trois commandes.

---

## Architecture technique

```
┌─────────────────────────────────────────────────────────┐
│                    UTILISATEUR                           │
│                                                         │
│   CLI: aneforge train / create / learn / chat / info    │
│   API: from aneforge import Trainer                     │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                 PYTHON (aneforge/)                       │
│                                                         │
│   trainer.py    - Orchestrateur d'entrainement          │
│   personal.py   - Gestion modele personnel              │
│   model.py      - Chargement HuggingFace                │
│   data.py       - Pipeline donnees (txt/jsonl/csv/chat) │
│   config.py     - Auto-detection & configuration        │
│   monitor.py    - Dashboard temps reel                  │
│   cli.py        - Interface ligne de commande           │
│   export.py     - Export GGUF/CoreML/safetensors        │
└────────────────────────┬────────────────────────────────┘
                         │ PyO3 bindings
┌────────────────────────▼────────────────────────────────┐
│                    RUST (crates/)                        │
│                                                         │
│   ane-core/                                             │
│     lora.rs       - LoRA/QLoRA (innovation cle)         │
│     forward.rs    - Forward pass hybride ANE+CPU        │
│     backward.rs   - Backward pass & gradients           │
│     optimizer.rs  - AdamW avec gradient clipping        │
│     mil.rs        - Generateur MIL (builder pattern)    │
│     model.rs      - 9 architectures pre-configurees     │
│     checkpoint.rs - Sauvegarde/reprise                  │
│     process.rs    - Gestion limite 119 compilations     │
│     scheduler.rs  - Pipeline multi-couches              │
│     kernels/      - Attention, FFN, Norm, LoRA fusionne │
│                                                         │
│   ane-sys/                                              │
│     runtime.rs    - Wrapper safe autour des APIs ANE    │
│     surface.rs    - IOSurface (memoire partagee CPU↔ANE)│
│     compiler.rs   - Compilation MIL → binaire ANE      │
│     detect.rs     - Detection hardware M1-M5           │
│                                                         │
│   ane-python/                                           │
│     lib.rs        - Bindings PyO3 → Python              │
└────────────────────────┬────────────────────────────────┘
                         │ FFI (objc_msgSend)
┌────────────────────────▼────────────────────────────────┐
│              OBJECTIVE-C (ane_bridge.m)                  │
│                                                         │
│   _ANEClient    → Connexion au Neural Engine            │
│   _ANECompiler  → Compilation MIL en temps reel         │
│   IOSurface     → Transfert tenseurs CPU ↔ ANE          │
│   Accelerate    → BLAS pour gradients poids (CPU)       │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│              APPLE NEURAL ENGINE (hardware)              │
│                                                         │
│   M1: 11 TOPS  │ M2: 15.8 TOPS │ M3: 18 TOPS          │
│   M4: 38 TOPS  │ M5: 38+ TOPS                          │
│                                                         │
│   Efficacite: ~6.6 TFLOPS/watt (80x un A100)           │
└─────────────────────────────────────────────────────────┘
```

## Innovation cle : LoRA sur ANE

Le probleme fondamental de l'entrainement sur ANE est que les poids sont
"cuites" dans le code MIL compile. Chaque mise a jour de poids necessite
une recompilation complete (~500ms), et l'ANE a une limite de ~119
compilations par processus.

Notre solution : **LoRA (Low-Rank Adaptation)**

- Les poids de base du modele sont compiles UNE SEULE FOIS (statiques)
- Seuls les petits adapteurs LoRA (rang 8-32) sont recompiles
- Un adapteur rang-16 sur dim=768 = 24K parametres vs 590K pour la couche complete
- Recompilation ~10x plus rapide (petits kernels)
- La limite de 119 compilations devient gerable

```
Forward pass:  y = W_base @ x + (scale * B @ A @ x)
                   ──────────   ─────────────────────
                   Compile 1x   Recompile a chaque step
                   (statique)   (petit, rapide)
```

## Auto-configuration hardware

ANEForge detecte automatiquement votre Mac et configure les parametres optimaux :

| Chip | LoRA Rank | Seq Len | Batch | Grad Accum | TOPS ANE | Bande passante |
|------|-----------|---------|-------|------------|----------|----------------|
| M1       | 8     | 256     | 1     | 8          | 11       | 68 GB/s        |
| M1 Pro   | 16    | 512     | 1     | 4          | 11       | 200 GB/s       |
| M1 Max   | 16    | 512     | 2     | 4          | 11       | 400 GB/s       |
| M2       | 16    | 512     | 1     | 4          | 15.8     | 100 GB/s       |
| M2 Pro   | 16    | 512     | 2     | 4          | 15.8     | 200 GB/s       |
| M2 Max   | 32    | 1024    | 2     | 2          | 15.8     | 400 GB/s       |
| M3       | 16    | 512     | 2     | 4          | 18       | 100 GB/s       |
| M3 Pro   | 32    | 1024    | 2     | 2          | 18       | 200 GB/s       |
| M3 Max   | 32    | 1024    | 4     | 2          | 18       | 400 GB/s       |
| M4       | 32    | 1024    | 2     | 2          | 38       | 120 GB/s       |
| M4 Pro   | 32    | 1024    | 4     | 2          | 38       | 273 GB/s       |
| M4 Max   | 64    | 2048    | 4     | 1          | 38       | 546 GB/s       |
| M5       | 32    | 1024    | 4     | 2          | 38+      | 120 GB/s       |
| M5 Pro*  | 64    | 2048    | 4     | 1          | 38+      | 307 GB/s       |
| M5 Max*  | 64    | 2048    | 8     | 1          | 38+      | 614 GB/s       |

*M5 Pro et M5 Max utilisent la Fusion Architecture avec des Neural Accelerators
dans chaque coeur GPU (20 sur Pro, 40 sur Max), offrant 4x le compute IA GPU
par rapport a la generation precedente.

## Modeles supportes

| Modele | Parametres | Usage recommande |
|--------|-----------|-----------------|
| SmolLM2-135M | 135M | Experimentation rapide, debutants |
| SmolLM2-360M | 360M | Assistant personnel leger |
| Qwen2.5-0.5B | 500M | Multilingue, code |
| TinyLlama-1.1B | 1.1B | Chat general |
| Llama-3.2-1B | 1.2B | Performance equilibree |
| Gemma-2-2B | 2.6B | Haute qualite |
| Phi-3-mini | 3.8B | Raisonnement (necessite 16GB+) |

## Modele personnel

Chaque utilisateur peut creer, entrainer et faire evoluer son propre modele :

```python
from aneforge import PersonalModel

# Creer
model = PersonalModel.create("mon-ia", base="smollm2-360m")

# Entrainer sur vos donnees
model.learn("emails.txt")        # Session 1 → v1
model.learn("notes.txt")         # Session 2 → v2 (incremental)
model.learn("conversations.txt") # Session 3 → v3

# Chaque session cree une version
# Les adapteurs LoRA s'empilent et se fusionnent

# Voir l'historique
model.print_info()
```

Votre modele est stocke localement dans `~/.aneforge/models/`.
Vos donnees ne quittent jamais votre Mac.

---

## Stack technique

| Couche | Langage | Pourquoi |
|--------|---------|----------|
| ANE Bridge | Objective-C | Seul moyen d'acceder aux APIs privees Apple |
| Core Engine | Rust | Securite memoire pour IOSurface, performance, FFI ObjC natif |
| Bindings | PyO3 | Bindings Python natifs depuis Rust, zero overhead |
| Interface | Python | Ecosysteme ML (HuggingFace), accessibilite maximale |

## Dependances

**Minimales par design :**
- Rust : objc2, pyo3, half, serde, thiserror
- Python : huggingface_hub, tokenizers, safetensors, rich, typer, numpy
- Systeme : macOS 15+, Apple Silicon (M1+), Xcode CLI Tools

---

## 3 niveaux d'utilisation

### Novice (zero connaissance ML)
```bash
pip install aneforge
aneforge create mon-ia --base smollm2
aneforge learn mon-ia --data mes-notes.txt
aneforge chat mon-ia
```

### Intermediaire
```bash
aneforge train Qwen/Qwen2.5-0.5B \
  --data dataset.jsonl \
  --format chat \
  --lora-rank 16 \
  --epochs 3 \
  --output ./mon-modele
```

### Expert
```python
from aneforge import Trainer, ANEConfig

config = ANEConfig(
    backend="ane",
    lora_rank=32,
    seq_len=1024,
    compile_budget=100,
    ane_qos=21,
)

trainer = Trainer("meta-llama/Llama-3.2-1B", config=config)
trainer.load_data("data.jsonl", format="chat")
trainer.train(epochs=3, lr=2e-4, callbacks=[my_callback])
trainer.export("gguf", "model.gguf")
```

---

## Avertissements

- ANEForge utilise des **APIs privees Apple** non documentees
- Ces APIs peuvent changer ou casser a chaque mise a jour macOS
- Ce projet est experimental et destine a la recherche/education
- Ne pas utiliser en production sans tests approfondis
- Les performances reelles dependent du modele, des donnees et du hardware
