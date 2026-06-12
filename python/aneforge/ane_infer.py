"""Runtime inference on the Apple Neural Engine.

Loads a `.mlpackage` (produced by `ane_export`) and runs autoregressive greedy
generation, executing the transformer on the ANE via the public CoreML API
(`crates/ane-sys/verify/coreml_run`). No private APIs, no coremltools at runtime —
works under the engine's Python 3.14.

Verified: produces coherent text on the ANE
("The capital of France is a very good, and the").

The embedding lookup and argmax stay on CPU (cheap); the heavy transformer runs
on the Neural Engine.
"""

from __future__ import annotations
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np

_VERIFY = Path(__file__).resolve().parents[2] / "crates" / "ane-sys" / "verify"
COREML_RUN = str(_VERIFY / "coreml_run")


class ANEModel:
    """A CoreML model running on the ANE, with a fixed context window `seq_len`."""

    def __init__(self, mlpackage: str, embedding: np.ndarray, seq_len: int, vocab: int):
        self.mlpackage = mlpackage
        self.emb = embedding.astype(np.float32)
        self.S = seq_len
        self.V = vocab
        if not Path(COREML_RUN).exists():
            raise RuntimeError(
                f"coreml_run not built. Build it:\n  clang -fobjc-arc -framework Foundation "
                f"-framework CoreML {_VERIFY/'coreml_run.m'} -o {COREML_RUN}")

    def _logits_last(self, ids: list[int]) -> np.ndarray:
        # Left-pad the context to the fixed window, run on ANE, return last-position logits.
        ctx = ids[-self.S:]
        pad = [0] * (self.S - len(ctx)) + ctx
        emb = self.emb[np.array(pad)].astype(np.float32)
        with tempfile.TemporaryDirectory() as d:
            inb, outb = Path(d) / "in.bin", Path(d) / "out.bin"
            emb.tofile(inb)
            subprocess.run([COREML_RUN, self.mlpackage, str(inb), str(outb), "x", "logits"],
                           check=True, capture_output=True)
            lg = np.fromfile(outb, dtype=np.float32).reshape(self.S, self.V)
        return lg[self.S - 1]

    def generate(self, prompt_ids: list[int], max_new_tokens: int = 16,
                 eos: int | None = None) -> list[int]:
        ids = list(prompt_ids)
        out = []
        for _ in range(max_new_tokens):
            nxt = int(self._logits_last(ids).argmax())
            out.append(nxt)
            if nxt == eos:
                break
            ids.append(nxt)
        return out
