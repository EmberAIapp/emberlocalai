"""Personal model management - create, train, and evolve your own AI model."""

import json
import shutil
import time
from pathlib import Path
from typing import Optional

ANEFORGE_HOME = Path.home() / ".aneforge"
MODELS_DIR = ANEFORGE_HOME / "models"


class PersonalModel:
    """
    Your personal AI model that learns and evolves with you.

    Usage:
        model = PersonalModel.create("mon-assistant", base="smollm2")
        model.learn("mes-notes.txt")
        model.learn("nouvelles-donnees.txt")  # Incremental learning
        model.chat("Bonjour!")
        model.info()
    """

    def __init__(self, name: str):
        self.name = name
        self.path = MODELS_DIR / name
        self.config_path = self.path / "config.json"
        self.versions_dir = self.path / "versions"

        if not self.path.exists():
            raise ValueError(
                f"Model '{name}' not found. Create it first with: "
                f"PersonalModel.create('{name}', base='smollm2')"
            )

        self._config = self._load_config()

    @classmethod
    def create(
        cls,
        name: str,
        base: str = "smollm2-135m",
        description: str = "",
    ) -> "PersonalModel":
        """Create a new personal model."""
        model_dir = MODELS_DIR / name
        if model_dir.exists():
            raise ValueError(f"Model '{name}' already exists. Use PersonalModel('{name}') to load it.")

        model_dir.mkdir(parents=True, exist_ok=True)
        versions_dir = model_dir / "versions"
        versions_dir.mkdir(exist_ok=True)

        config = {
            "name": name,
            "base_model": base,
            "description": description,
            "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "version": 0,
            "total_training_steps": 0,
            "training_sessions": [],
        }

        with open(model_dir / "config.json", "w") as f:
            json.dump(config, f, indent=2)

        print(f"Created personal model '{name}' (base: {base})")
        print(f"Location: {model_dir}")
        print(f"Train it with: model.learn('your_data.txt')")

        return cls(name)

    @classmethod
    def list_models(cls) -> list[dict]:
        """List all personal models."""
        models = []
        if MODELS_DIR.exists():
            for model_dir in sorted(MODELS_DIR.iterdir()):
                config_path = model_dir / "config.json"
                if config_path.exists():
                    with open(config_path) as f:
                        config = json.load(f)
                    models.append(config)
        return models

    def learn(
        self,
        data_path: str,
        epochs: int = 1,
        lr: Optional[float] = None,
    ) -> None:
        """
        Train the model on new data (incremental learning).
        Each training session creates a new version.
        """
        from aneforge.trainer import Trainer
        from aneforge.config import auto_config

        config = auto_config(self._config["base_model"])

        # Personal-memorization recipe (the one that makes the model recall YOUR
        # facts): LoRA on all 7 projections, a memorization-friendly LR, and
        # enough steps. Cosine decay + best-loss checkpoint make over-training safe.
        config.target_modules = [
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ]
        config.lora_alpha = config.lora_rank * 2.0
        config.learning_rate = lr if lr else 1e-3

        trainer = Trainer(self._config["base_model"], config=config)
        trainer.load_data(data_path)

        # Drive loss low enough for hard recall — but NOT to ~0, which over-fits
        # a tiny corpus into a rigid parrot that recites from the start. Aim for
        # solid memorization (~0.1-0.5) by scaling steps modestly with corpus size.
        n_tokens = len(trainer._data_tokens or [])
        seq = config.seq_len
        n_samples = max(1, n_tokens // max(1, seq))
        steps = max(40, n_samples * 12) * epochs
        losses = trainer.train(steps=steps)

        # Save as new version
        self._config["version"] += 1
        version = self._config["version"]

        version_dir = self.versions_dir / f"v{version}"
        trainer.save(str(version_dir))

        # Update config
        session = {
            "version": version,
            "data": data_path,
            "epochs": epochs,
            "steps": trainer.step,
            "final_loss": losses[-1] if losses else None,
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        self._config["training_sessions"].append(session)
        self._config["total_training_steps"] += trainer.step
        self._save_config()

        print(f"\nModel '{self.name}' updated to v{version}")
        print(f"Total training: {self._config['total_training_steps']} steps across {version} sessions")

    def info(self) -> dict:
        """Get model information."""
        info = {
            "name": self._config["name"],
            "base": self._config["base_model"],
            "version": self._config["version"],
            "created": self._config["created_at"],
            "total_steps": self._config["total_training_steps"],
            "sessions": len(self._config["training_sessions"]),
            "location": str(self.path),
        }
        return info

    def print_info(self) -> None:
        """Pretty print model information."""
        info = self.info()
        print(f"\n  Personal Model: {info['name']}")
        print(f"  Base: {info['base']}")
        print(f"  Version: v{info['version']}")
        print(f"  Created: {info['created']}")
        print(f"  Training: {info['total_steps']} steps, {info['sessions']} sessions")
        print(f"  Location: {info['location']}")

        if self._config["training_sessions"]:
            print(f"\n  Training History:")
            for session in self._config["training_sessions"]:
                loss_str = f"loss={session['final_loss']:.4f}" if session['final_loss'] else ""
                print(f"    v{session['version']}: {session['data']} ({session['steps']} steps, {loss_str})")

    def delete(self, confirm: bool = False) -> None:
        """Delete this personal model."""
        if not confirm:
            print(f"Are you sure? Call .delete(confirm=True) to permanently delete '{self.name}'")
            return

        shutil.rmtree(self.path)
        print(f"Deleted model '{self.name}'")

    def _load_config(self) -> dict:
        with open(self.config_path) as f:
            return json.load(f)

    def _save_config(self) -> None:
        with open(self.config_path, "w") as f:
            json.dump(self._config, f, indent=2)
