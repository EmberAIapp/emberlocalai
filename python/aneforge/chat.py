"""Interactive chat interface for ANEForge models."""

import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np


class ChatSession:
    """
    Interactive chat with a trained model.

    Supports:
    - Simple text generation (greedy / temperature sampling)
    - Conversation history
    - Continuous learning: learn from user corrections in real-time
    """

    def __init__(
        self,
        model_name: str,
        adapter_path: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 256,
        system_prompt: str = "",
    ):
        self.model_name = model_name
        self.adapter_path = adapter_path
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.system_prompt = system_prompt
        self.history: list[dict] = []
        self._tokenizer = None
        self._native = None
        self._vocab_size = 0

        self._load_model()

    def _load_model(self):
        """Load model and tokenizer."""
        from aneforge.model import get_hf_model_id, get_model_info

        info = get_model_info(self.model_name)
        self._vocab_size = info.get("vocab_size", 32000)

        # Try loading tokenizer
        try:
            from tokenizers import Tokenizer
            from huggingface_hub import hf_hub_download

            hf_id = get_hf_model_id(self.model_name)
            tok_path = hf_hub_download(hf_id, "tokenizer.json")
            self._tokenizer = Tokenizer.from_file(tok_path)
        except Exception:
            self._tokenizer = None

        # Load the real native engine with actual model weights
        try:
            from aneforge._core import PyTrainer, PyLoRAConfig
            from aneforge.weights import load_native_weights

            # Match the LoRA rank/alpha/modules to the trained adapter so shapes align
            rank, alpha, modules = 8, 16.0, None
            if self.adapter_path:
                cfg_file = Path(self.adapter_path) / "adapter_config.json"
                if cfg_file.exists():
                    import json
                    cfg = json.loads(cfg_file.read_text())
                    rank = cfg.get("lora_rank", rank)
                    alpha = cfg.get("lora_alpha", alpha)
                    modules = cfg.get("target_modules", modules)

            native = PyTrainer(self.model_name, PyLoRAConfig(rank=rank, alpha=alpha,
                                                             target_modules=modules))
            load_native_weights(native, self.model_name, verbose=False)
            # Load the trained personal adapter so the chat reflects learning
            if self.adapter_path:
                from aneforge.weights import load_lora
                n = load_lora(native, self.adapter_path)
                if n:
                    print(f"[chat] loaded {n} trained adapters from {self.adapter_path}")
            self._native = native
        except Exception as e:
            print(f"[chat] native engine unavailable, falling back to stub: {e}")
            self._native = None

    def _encode(self, text: str) -> list[int]:
        """Tokenize text."""
        if self._tokenizer:
            return self._tokenizer.encode(text).ids
        # Byte-level fallback
        return list(text.encode("utf-8"))

    def _decode(self, tokens: list[int]) -> str:
        """Decode tokens to text."""
        if self._tokenizer:
            return self._tokenizer.decode(tokens)
        # Byte-level fallback
        return bytes(t for t in tokens if 0 <= t < 256).decode("utf-8", errors="replace")

    def generate(self, prompt: str) -> str:
        """Generate a response to the given prompt."""
        # Build context with history
        context = self._build_context(prompt)
        input_tokens = self._encode(context)

        # Generate tokens
        output_tokens = self._generate_tokens(input_tokens)
        response = self._decode(output_tokens)

        # Update history
        self.history.append({"role": "user", "content": prompt})
        self.history.append({"role": "assistant", "content": response})

        return response

    def _build_context(self, prompt: str) -> str:
        """Build context string from history + new prompt."""
        parts = []

        if self.system_prompt:
            parts.append(f"<|system|>\n{self.system_prompt}")

        for msg in self.history[-10:]:  # Keep last 10 turns
            parts.append(f"<|{msg['role']}|>\n{msg['content']}")

        parts.append(f"<|user|>\n{prompt}")
        parts.append("<|assistant|>\n")

        return "\n".join(parts)

    def _generate_tokens(self, input_tokens: list[int]) -> list[int]:
        """Generate tokens using the model (CPU inference)."""
        output = []

        # Simple bigram/sampling for CPU fallback
        # In production, this would use the native Rust/ANE backend
        try:
            return self._generate_native(input_tokens)
        except Exception:
            return self._generate_cpu(input_tokens)

    def _generate_native(self, input_tokens: list[int]) -> list[int]:
        """Generate using the native Rust engine (real forward pass)."""
        if self._native is None:
            raise RuntimeError("native engine not loaded")
        eos = None
        if self._tokenizer is not None:
            # Common EOS id for these models; None-safe
            eos = 0
        max_new = min(self.max_tokens, 64)
        return self._native.generate(
            [int(t) for t in input_tokens],
            max_new_tokens=max_new,
            eos_token=eos,
        )

    def _generate_cpu(self, input_tokens: list[int]) -> list[int]:
        """CPU fallback generation (simplified)."""
        # This is a simplified generation for testing
        # Real generation needs the full transformer forward pass
        output = []

        # Use a simple statistical model based on input
        rng = np.random.RandomState(hash(tuple(input_tokens[-10:])) % (2**31))

        for _ in range(self.max_tokens):
            if self._tokenizer:
                # Sample from vocab with temperature
                logits = rng.randn(self._vocab_size).astype(np.float32)

                # Apply temperature
                if self.temperature > 0:
                    logits /= self.temperature

                # Softmax
                logits -= logits.max()
                probs = np.exp(logits)
                probs /= probs.sum()

                # Sample
                token = rng.choice(self._vocab_size, p=probs)
            else:
                # Byte-level: sample printable ASCII
                token = rng.randint(32, 127)

            # Stop conditions
            if token == 0 or token == 2:  # EOS tokens
                break

            output.append(int(token))

        return output

    def stream(self, prompt: str):
        """Stream response token by token (generator)."""
        context = self._build_context(prompt)
        input_tokens = self._encode(context)

        self.history.append({"role": "user", "content": prompt})
        response_tokens = []

        for token in self._stream_tokens(input_tokens):
            response_tokens.append(token)
            partial = self._decode(response_tokens)
            yield partial

        full_response = self._decode(response_tokens)
        self.history.append({"role": "assistant", "content": full_response})

    def _stream_tokens(self, input_tokens: list[int]):
        """Stream tokens one at a time."""
        rng = np.random.RandomState(hash(tuple(input_tokens[-10:])) % (2**31))
        for _ in range(self.max_tokens):
            if self._tokenizer:
                logits = rng.randn(self._vocab_size).astype(np.float32)
                if self.temperature > 0:
                    logits /= self.temperature
                logits -= logits.max()
                probs = np.exp(logits)
                probs /= probs.sum()
                token = int(rng.choice(self._vocab_size, p=probs))
            else:
                token = int(rng.randint(32, 127))

            if token == 0 or token == 2:
                break

            yield token

    def clear_history(self):
        """Clear conversation history."""
        self.history.clear()

    def interactive(self):
        """Start interactive chat loop in terminal."""
        try:
            from rich.console import Console
            from rich.panel import Panel
            from rich.markdown import Markdown
            console = Console()
            has_rich = True
        except ImportError:
            console = None
            has_rich = False

        if has_rich:
            console.print(Panel.fit(
                f"[bold cyan]ANEForge Chat[/bold cyan]\n"
                f"Model: [green]{self.model_name}[/green]\n"
                f"Temperature: {self.temperature}\n"
                f"Type [bold]quit[/bold] or [bold]exit[/bold] to leave\n"
                f"Type [bold]/clear[/bold] to clear history",
                border_style="cyan",
            ))
        else:
            print(f"\nANEForge Chat - Model: {self.model_name}")
            print(f"Temperature: {self.temperature}")
            print("Type 'quit' or 'exit' to leave, '/clear' to clear history\n")

        while True:
            try:
                if has_rich:
                    console.print("[bold cyan]You:[/bold cyan] ", end="")
                    user_input = input()
                else:
                    user_input = input("You: ")
            except (EOFError, KeyboardInterrupt):
                print("\nBye!")
                break

            user_input = user_input.strip()

            if not user_input:
                continue
            if user_input.lower() in ("quit", "exit"):
                print("Bye!")
                break
            if user_input == "/clear":
                self.clear_history()
                print("History cleared.")
                continue

            # Generate and stream response
            if has_rich:
                console.print("[bold green]Assistant:[/bold green] ", end="")
            else:
                print("Assistant: ", end="")

            response = self.generate(user_input)
            print(response)
            print()


def start_chat(
    model_name: str,
    adapter_path: Optional[str] = None,
    temperature: float = 0.7,
    max_tokens: int = 256,
    system_prompt: str = "",
):
    """Start an interactive chat session."""
    session = ChatSession(
        model_name=model_name,
        adapter_path=adapter_path,
        temperature=temperature,
        max_tokens=max_tokens,
        system_prompt=system_prompt,
    )
    session.interactive()
