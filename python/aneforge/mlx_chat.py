"""MLX chat backend — fluent local conversation on Apple Silicon.

Proven on M5: Qwen2.5-1.5B-Instruct-4bit → fluent French, grounds injected facts,
~56 tok/s warm. This is the primary INFERENCE path for chat (the Rust/ANE engine
stays for personal LoRA training). Loaded once (heavy), reused across turns — hence
the daemon (see ember_daemon.py); never load per-message.
"""

from __future__ import annotations

DEFAULT_MODEL = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"


class MLXChat:
    def __init__(self, model_id: str = DEFAULT_MODEL):
        from mlx_lm import load
        self.model_id = model_id
        self.model, self.tok = load(model_id)

    @staticmethod
    def available() -> bool:
        try:
            import mlx_lm  # noqa: F401
            return True
        except Exception:
            return False

    @staticmethod
    def _sampler(temperature: float | None):
        """Real temperature via mlx_lm's sampler (None → library default / greedy-ish)."""
        if temperature is None:
            return None
        try:
            from mlx_lm.sample_utils import make_sampler
            return make_sampler(temp=max(0.0, float(temperature)))
        except Exception:
            return None

    def chat(self, messages: list[dict], max_tokens: int = 220, temperature: float | None = None) -> str:
        """messages: [{role: system|user|assistant, content: ...}] -> answer text."""
        from mlx_lm import generate
        prompt = self.tok.apply_chat_template(messages, add_generation_prompt=True)
        s = self._sampler(temperature)
        kw = {"sampler": s} if s is not None else {}
        out = generate(self.model, self.tok, prompt=prompt, max_tokens=max_tokens, verbose=False, **kw)
        return out.strip()

    def stream(self, messages: list[dict], max_tokens: int = 220, temperature: float | None = None):
        """Yield text deltas token-by-token — for live, token-by-token replies (§5.4)."""
        from mlx_lm import stream_generate
        prompt = self.tok.apply_chat_template(messages, add_generation_prompt=True)
        s = self._sampler(temperature)
        kw = {"sampler": s} if s is not None else {}
        for resp in stream_generate(self.model, self.tok, prompt=prompt, max_tokens=max_tokens, **kw):
            piece = getattr(resp, "text", None)
            if piece:
                yield piece
