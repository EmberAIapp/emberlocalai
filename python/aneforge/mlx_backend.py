"""MLX backend fallback for training when ANE is unavailable.

Uses Apple's MLX framework which runs on Metal GPU.
This provides a much better fallback than pure CPU training.
"""

from typing import Optional
import time


def is_mlx_available() -> bool:
    """Check if MLX is installed and usable."""
    try:
        import mlx.core as mx
        import mlx.nn as nn
        import mlx.optimizers as optim
        return True
    except ImportError:
        return False


class MLXTrainer:
    """
    Training backend using Apple's MLX framework (Metal GPU).

    Falls back to this when ANE is not available.
    MLX provides good performance on Apple Silicon via Metal.
    """

    def __init__(
        self,
        model_name: str,
        lora_rank: int = 16,
        lora_alpha: float = 32.0,
        target_modules: Optional[list[str]] = None,
    ):
        if not is_mlx_available():
            raise ImportError(
                "MLX not installed. Install with: pip install mlx mlx-lm\n"
                "MLX requires macOS 13.5+ and Apple Silicon."
            )

        import mlx.core as mx

        self.model_name = model_name
        self.lora_rank = lora_rank
        self.lora_alpha = lora_alpha
        self.target_modules = target_modules or ["q_proj", "v_proj"]
        self._model = None
        self._tokenizer = None
        self.step = 0
        self.losses: list[float] = []

    def load_model(self):
        """Load model from HuggingFace using mlx-lm."""
        try:
            from mlx_lm import load
            from aneforge.model import get_hf_model_id

            hf_id = get_hf_model_id(self.model_name)
            print(f"Loading {hf_id} with MLX...")
            self._model, self._tokenizer = load(hf_id)
            print(f"Model loaded on Metal GPU")
        except ImportError:
            raise ImportError(
                "mlx-lm not installed. Install with: pip install mlx-lm\n"
                "This is needed to load HuggingFace models with MLX."
            )

    def apply_lora(self):
        """Apply LoRA adapters to the model."""
        try:
            import mlx.core as mx
            import mlx.nn as nn
            from mlx_lm.tuner.lora import LoRALinear
        except ImportError:
            raise ImportError("mlx-lm required for LoRA. Install: pip install mlx-lm")

        if self._model is None:
            self.load_model()

        # Apply LoRA to target modules
        def apply_lora_layers(model):
            for name, module in model.named_modules():
                for target in self.target_modules:
                    if target in name and isinstance(module, nn.Linear):
                        lora_layer = LoRALinear.from_linear(
                            module,
                            r=self.lora_rank,
                            alpha=self.lora_alpha,
                        )
                        # Replace the module
                        parts = name.split(".")
                        parent = model
                        for part in parts[:-1]:
                            parent = getattr(parent, part)
                        setattr(parent, parts[-1], lora_layer)

        apply_lora_layers(self._model)

        # Freeze all except LoRA
        self._model.freeze()
        for name, param in self._model.named_parameters():
            if "lora" in name.lower():
                param.requires_grad = True

        trainable = sum(p.size for _, p in self._model.trainable_parameters())
        total = sum(p.size for _, p in self._model.parameters())
        print(f"LoRA applied: {trainable:,} trainable / {total:,} total ({trainable/total*100:.2f}%)")

    def train(
        self,
        tokens: list[int],
        steps: int = 100,
        lr: float = 1e-4,
        seq_len: int = 256,
        batch_size: int = 1,
    ) -> list[float]:
        """Train using MLX on Metal GPU."""
        import mlx.core as mx
        import mlx.optimizers as optim

        if self._model is None:
            self.load_model()
            self.apply_lora()

        optimizer = optim.AdamW(learning_rate=lr)

        # Prepare data
        tokens_array = mx.array(tokens)
        n_samples = max(1, len(tokens) // seq_len)

        losses = []
        start = time.time()

        def loss_fn(model, x, y):
            logits = model(x)
            return mx.mean(nn.losses.cross_entropy(logits, y))

        loss_and_grad = mx.value_and_grad(loss_fn)

        for step_i in range(steps):
            idx = (step_i % n_samples) * seq_len
            x = tokens_array[idx:idx + seq_len].reshape(batch_size, -1)
            y = tokens_array[idx + 1:idx + seq_len + 1].reshape(batch_size, -1)

            loss, grads = loss_and_grad(self._model, x, y)
            optimizer.update(self._model, grads)
            mx.eval(self._model.parameters(), optimizer.state)

            loss_val = loss.item()
            losses.append(loss_val)
            self.step += 1
            self.losses.append(loss_val)

            if step_i % 10 == 0:
                elapsed = time.time() - start
                speed = (step_i + 1) / elapsed if elapsed > 0 else 0
                print(
                    f"  [MLX] step {step_i:>5d}/{steps} | loss {loss_val:.4f} | "
                    f"{speed:.1f} steps/s"
                )

        elapsed = time.time() - start
        print(f"\nMLX training complete: {steps} steps in {elapsed:.1f}s")
        if losses:
            print(f"Final loss: {losses[-1]:.4f}")

        return losses

    def save_adapter(self, path: str):
        """Save LoRA adapter weights."""
        import mlx.core as mx
        from pathlib import Path
        import json

        out_dir = Path(path)
        out_dir.mkdir(parents=True, exist_ok=True)

        # Save LoRA weights
        weights = {}
        for name, param in self._model.trainable_parameters():
            weights[name] = param
        mx.savez(str(out_dir / "lora_weights.npz"), **weights)

        # Save config
        config = {
            "model": self.model_name,
            "lora_rank": self.lora_rank,
            "lora_alpha": self.lora_alpha,
            "target_modules": self.target_modules,
            "steps": self.step,
            "final_loss": self.losses[-1] if self.losses else None,
            "backend": "mlx",
        }
        with open(out_dir / "adapter_config.json", "w") as f:
            json.dump(config, f, indent=2)

        print(f"Saved MLX LoRA adapter to {out_dir}")

    def generate(self, prompt: str, max_tokens: int = 256, temperature: float = 0.7) -> str:
        """Generate text using MLX model."""
        try:
            from mlx_lm import generate as mlx_generate

            if self._model is None:
                self.load_model()

            return mlx_generate(
                self._model,
                self._tokenizer,
                prompt=prompt,
                max_tokens=max_tokens,
                temp=temperature,
            )
        except Exception as e:
            raise RuntimeError(f"MLX generation failed: {e}")
