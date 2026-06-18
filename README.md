# Ember

**Your local-first personal AI for macOS. Your AI, your memory, your conversations — on your Mac.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1+-black.svg)]()
[![Download](https://img.shields.io/badge/Download-macOS-ff7a3c.svg)](https://emberlocalai.com)

Ember is a personal AI that learns from your data and remembers you. You talk to it
out loud, it answers — and its model, memory and conversations run **on your Mac**.
No account, no sign-up, no cloud by default.

→ **Download for macOS:** **https://emberlocalai.com**
→ DMG mirror: https://huggingface.co/EmberAIapp/ember-app

---

## What it does

- **🗣️ Talk (Her Mode)** — voice or text. On-device chat (Qwen2.5 via [MLX](https://github.com/ml-explore/mlx)); Ember answers out loud.
- **🧠 Memory you control** — Ember files what it learns about you as plain-language facts you can **read, edit, or delete**. Stored locally.
- **📥 Learn from your data** — drop in notes, files and folders, or connect Apple Notes. Facts are extracted on-device.
- **⚙️ Optional work agent** — hand Ember a real task. The agent can call an external cloud AI model — **only with your per-action consent**. This is the one feature that can reach the cloud.

## Privacy — the honest version

- Your **AI, memory and conversations run on your Mac** (MLX inference + local storage).
- The **only** thing that can reach the cloud is the **optional work agent**, which calls an external AI model (currently DeepSeek), and **only when you approve it, action by action**.
- No telemetry. No account. No tracking.

## Install

Download the DMG from **https://emberlocalai.com**, open it, drag **Ember** to Applications.

**Unsigned beta** (not yet notarized — that needs an Apple Developer account). To open on macOS:

- Open Ember once, then go to **System Settings → Privacy & Security → Open Anyway**, **or**
- In Terminal: `xattr -dr com.apple.quarantine /Applications/Ember.app`

Requirements: **macOS 14+, Apple Silicon (M1 or later)**. ~2.2 GB (the model ships inside, so it works fully offline).

## Architecture

```
SwiftUI app  ─►  local Python daemon  ─►  MLX inference (on-device)
(app/ANEForge)   (ember_daemon.py)        (Qwen2.5-1.5B-Instruct-4bit)
                       │
                       ├─►  retrieval memory (facts) + neural TTS (Kokoro)
                       └─►  optional work agent  ─►  external cloud model (consent-gated)
```

- **App** — [`app/ANEForge`](app/ANEForge) — native SwiftUI macOS app (Swift 6).
- **Engine** — [`python/aneforge`](python/aneforge) — local daemon (`ember_daemon.py`), MLX chat (`mlx_chat.py`), editable memory (`memory.py`), voice (`tts.py`), the work agent (`agent.py`).
- **Research (experimental)** — [`crates/`](crates) — Rust (`ane-core`, `ane-sys`): on-device training + Apple Neural Engine execution via Core ML. This is a separate research track from the shipped MLX app.

## Build from source

```bash
# dev build (binary only, uses your local engine — fast iteration)
EMBED_ENGINE=0 ./app/ANEForge/build_app.sh

# self-contained "any-Mac" build (embeds a relocatable Python + the models)
DIST=1 ./app/ANEForge/build_app.sh
```

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools, Python 3.10+.

## License

MIT — see [LICENSE](LICENSE).

---

Website **https://emberlocalai.com** · Hugging Face **https://huggingface.co/EmberAIapp** · made by [EmberAIapp](https://github.com/EmberAIapp)
