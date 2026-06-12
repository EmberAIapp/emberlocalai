"""ANE kernel execution from Python.

A `LinearKernel` wraps one weight matrix as an Apple Neural Engine kernel:
compilation to an MLProgram is an offline/setup step (needs coremltools, which
requires Python 3.12 — its native libs are broken on 3.14); execution at runtime
goes through the tiny `ane_run` ObjC executor and needs no Python ML deps.

This is the bridge that lets the Rust/Python engine offload its matmuls to the
ANE. Base weights are static (compiled once), which matches the LoRA design where
only the small adapters change.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np

# Locate the compiled `ane_run` executor (built from crates/ane-sys/verify/ane_run.m).
_VERIFY_DIR = Path(__file__).resolve().parents[2] / "crates" / "ane-sys" / "verify"
ANE_RUN = os.environ.get("ANEFORGE_ANE_RUN", str(_VERIFY_DIR / "ane_run"))


class ANEUnavailable(RuntimeError):
    pass


class LinearKernel:
    """Y = W @ X  for X of shape [in_dim, S], executed on the ANE.

    `mlpackage_path` is produced once by `compile_linear` (coremltools, py3.12).
    """

    def __init__(self, in_dim: int, out_dim: int, mlpackage_path: str):
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.mlpackage = mlpackage_path
        if not Path(ANE_RUN).exists():
            raise ANEUnavailable(
                f"ane_run executor not found at {ANE_RUN}. Build it:\n"
                f"  clang -fobjc-arc -framework Foundation -framework CoreML "
                f"-framework IOSurface {_VERIFY_DIR/'ane_run.m'} -o {_VERIFY_DIR/'ane_run'}"
            )

    def forward(self, x: np.ndarray) -> np.ndarray:
        """x: [in_dim, S] float32 -> [out_dim, S] float32, computed on the ANE."""
        assert x.shape[0] == self.in_dim, f"expected in_dim={self.in_dim}, got {x.shape}"
        S = x.shape[1]
        out_floats = self.out_dim * S
        with tempfile.TemporaryDirectory() as d:
            inb = Path(d) / "in.bin"
            outb = Path(d) / "out.bin"
            np.ascontiguousarray(x, dtype=np.float32).tofile(inb)
            r = subprocess.run(
                [ANE_RUN, self.mlpackage, str(inb), str(outb), str(out_floats)],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                raise ANEUnavailable(f"ane_run failed: {r.stderr.strip()}")
            y = np.fromfile(outb, dtype=np.float32)
        return y.reshape(self.out_dim, S)


def compile_linear(weight: np.ndarray, out_path: str, seq_len: int) -> str:
    """Compile a [out_dim, in_dim] weight matrix into an ANE MLProgram kernel.

    Requires coremltools (run under a Python 3.12 venv). Returns out_path.
    """
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    out_dim, in_dim = weight.shape
    Wc = weight.reshape(out_dim, in_dim, 1, 1).astype(np.float32)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, in_dim, 1, seq_len))])
    def prog(x):
        return mb.conv(x=x, weight=Wc, strides=[1, 1], pad_type="valid")

    ct.convert(
        prog, source="milinternal", convert_to="mlprogram",
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    ).save(out_path)
    return out_path
