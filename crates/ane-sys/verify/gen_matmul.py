"""Generate a real linear-layer (matmul) MLProgram for ANE validation.
Run with a Python 3.12 venv that has coremltools (3.14 native libs are broken):
    python3.12 -m venv /tmp/ct312 && /tmp/ct312/bin/pip install coremltools
    /tmp/ct312/bin/python gen_matmul.py
Produces /tmp/ane_matmul.mlpackage + mm_input.bin + mm_expected.bin (CPU reference).
Then: clang -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface \
        ane_matmul.m -o /tmp/ane_matmul && /tmp/ane_matmul
"""
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb

np.random.seed(42)
K, N, S = 64, 48, 16  # in_ch, out_ch, positions
W = (np.random.randn(N, K).astype(np.float32) * 0.1)
X = np.random.randn(K, S).astype(np.float32)
Y = W @ X  # CPU reference

@mb.program(input_specs=[mb.TensorSpec(shape=(1, K, 1, S))])
def prog(x):
    return mb.conv(x=x, weight=W.reshape(N, K, 1, 1), strides=[1, 1], pad_type="valid")

ct.convert(prog, source="milinternal", convert_to="mlprogram",
           compute_units=ct.ComputeUnit.CPU_AND_NE).save("/tmp/ane_matmul.mlpackage")
X.tofile("/tmp/mm_input.bin")
Y.tofile("/tmp/mm_expected.bin")
print(f"K={K} N={N} S={S} — mlpackage + reference IO written")
