# ANE execution — verified recipe (M5 / H16)

This directory holds the **proven** path for running compute on the Apple Neural
Engine via private APIs. Verified on Apple M5 (ANE family H16), macOS 26.x:

```
ANE compile: YES | load: YES | evaluate: YES
input=1.0 → output=2.0, 2048/2048 correct
>>> ANE EXECUTION VERIFIED <<<
```

## The correct API path (this is what works)

Our original `objc/ane_bridge.m` used `_ANECompiler` + `loadModel:error:` — **wrong
classes**, compilation always failed. The working path is the *in-memory model
descriptor*:

1. `MLModel compileModelAtURL:` on an **`.mlpackage` (MLProgram)** → gives `model.mil` + `weights/weight.bin`
2. `_ANEInMemoryModelDescriptor modelWithMILText:weights:optionsPlist:`
3. `_ANEInMemoryModel inMemoryModelWithDescriptor:`
4. pre-create tmpDir at `hexStringIdentifier` with the MIL + weights
5. `compileWithQoS:options:error:` (QoS 21)
6. `loadWithQoS:options:error:`
7. `_ANEIOSurfaceObject objectWithIOSurface:` for in/out buffers
8. `_ANERequest requestWithInputs:inputIndices:outputs:outputIndices:weightsBuffer:perfStats:procedureIndex:`
9. `evaluateWithQoS:options:request:error:`

Credit: API path reverse-engineered by maderix/ANE (MIT).

## Reproduce

```bash
# 1) Generate a tiny MLProgram (out = 2*in). coremltools' native libs are broken
#    on Python 3.14, so use a 3.12 venv:
python3.12 -m venv /tmp/ct312 && /tmp/ct312/bin/pip install coremltools
/tmp/ct312/bin/python - <<'PY'
import coremltools as ct
from coremltools.converters.mil import Builder as mb
@mb.program(input_specs=[mb.TensorSpec(shape=(1, 64, 1, 32))])
def prog(x): return mb.mul(x=x, y=2.0)
ct.convert(prog, source="milinternal", convert_to="mlprogram",
           compute_units=ct.ComputeUnit.CPU_AND_NE).save("/tmp/ane_test.mlpackage")
PY

# 2) Build & run the verifier
clang -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface \
    ane_verify.m -o /tmp/ane_verify && /tmp/ane_verify
```

## Real linear layer verified (ane_matmul.m + gen_matmul.py)

Beyond the toy `2*x`, a **real channel-mixing matmul** (linear layer 64→48 over 16
positions, random weights) runs on the ANE and matches the CPU reference:

```
ANE out      = 0.2542 1.3115 0.5386
CPU ref      = 0.2545 1.3114 0.5387
max abs error = 0.0012 (FP16 rounding) | 768/768 within 1e-2
>>> ANE MATMUL MATCHES CPU <<<
```

Confirms the core forward/backward primitive executes correctly on ANE, and that
the flat channel IOSurface layout holds for channel-mixing ops.

## What this unlocks / what's next

This removes the existential risk: **the ANE runs our compute, no entitlement wall
on M5.** Remaining engineering to wire it into training:

- Emit MIL for our forward/backward ops (matmul/conv/attention) instead of a toy mul
- Dynamic weight reload for LoRA adapters (note: weights are baked at compile time —
  see maderix `m5result.md`; must async-recompile or raise accumulation steps)
- Manage the ~119-compile-per-process limit (process pool)
- Validate ANE outputs against the CPU reference engine (we have one that converges)
