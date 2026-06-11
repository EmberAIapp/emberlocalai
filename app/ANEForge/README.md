# ANEForge — App macOS native

Le visage grand public d'ANEForge. Une app SwiftUI native qui pilote le moteur
Rust+Python : créer une IA, lui apprendre vos données par glisser-déposer,
discuter avec elle. Tout en local.

## Architecture

```
SwiftUI (cette app)
   │  AppState (@MainActor ObservableObject)
   │
   ├── Engine.swift  ──► sous-processus `aneforge` CLI
   │                        │
   │                        └── Python (aneforge) ──► Rust (_core) ──► [ANE/CPU]
```

Le pont app→moteur passe par la CLI (`aneforge create / learn / ask / models --json`).
Découplé et robuste : l'app n'embarque pas le moteur, elle le pilote. Une version
distribuée embarquerait un runtime Python ; en dev on pointe vers le venv du repo.

## Lancer (dev)

```bash
./run.sh          # définit les variables d'env et fait `swift run`
```

ou manuellement :

```bash
export ANEFORGE_PYTHON=/chemin/vers/.venv/bin/python
export ANEFORGE_PYTHONPATH=/chemin/vers/repo/python
swift run ANEForge
```

## Écrans

- **Accueil** : un bouton « Créer mon IA »
- **Créer** : nom + choix du modèle de base (libellés simples, pas de jargon)
- **Modèle** : barre « Apprendre » (glisser un .txt) + chat type iMessage

## État

- ✅ Pont moteur (`Engine.swift`) vérifié : Swift → CLI → moteur → rappel réel
- ✅ App compile et linke (`swift build`)
- ⬜ Bundle `.app` signé + runtime Python embarqué (distribution)
- ⬜ Backend ANE (actuellement CPU via Accelerate)
