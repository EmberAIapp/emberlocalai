"""Export a Llama-architecture model (SmolLM2 / Llama-3.2 / Qwen-style) to a
CoreML MLProgram that runs on the Apple Neural Engine.

This is a **build-time** step: it needs coremltools, whose native libs only work
on Python 3.12 (broken on 3.14). The produced `.mlpackage` is then executed at
runtime via the public CoreML API (`crates/ane-sys/verify/coreml_run.m`) — which
auto-partitions onto the ANE, needs no private APIs, and no coremltools.

Verified: full 30-layer SmolLM2-135M exported here predicts the same next token
as a numpy reference (argmax match); a single layer matches to 2e-5 in FP32.

The forward graph matches the ANEForge CPU engine convention (interleaved RoPE,
GQA, RMSNorm, SwiGLU). Embedding lookup and sampling stay on CPU (cheap); the
heavy matmuls/attention run on the ANE.

Run under a 3.12 venv:
    python3.12 -m venv /tmp/ct312 && /tmp/ct312/bin/pip install coremltools ml_dtypes huggingface_hub
    /tmp/ct312/bin/python -m aneforge.ane_export --model smollm2-135m --seq-len 32 --out model.mlpackage
"""

from __future__ import annotations
import numpy as np

# Architecture table (matches aneforge.config / Rust ModelConfig).
ARCH = {
    "smollm2-135m": dict(hf="HuggingFaceTB/SmolLM2-135M", dim=576, nh=9, nkv=3, hd=64,
                         nl=30, vocab=49152, eps=1e-5, theta=10000.0),
    "smollm2-360m": dict(hf="HuggingFaceTB/SmolLM2-360M", dim=960, nh=15, nkv=5, hd=64,
                         nl=32, vocab=49152, eps=1e-5, theta=10000.0),
}


def _load_weights(hf_id):
    import json, ml_dtypes
    from huggingface_hub import hf_hub_download
    raw = open(hf_hub_download(hf_id, "model.safetensors"), "rb").read()
    hlen = int.from_bytes(raw[:8], "little")
    hdr = json.loads(raw[8:8 + hlen]); base = 8 + hlen
    dt = {"F32": np.float32, "F16": np.float16, "BF16": ml_dtypes.bfloat16}
    W = {}
    for k, m in hdr.items():
        if k == "__metadata__":
            continue
        t = dt[m["dtype"]]; b, e = m["data_offsets"]
        a = np.frombuffer(raw, dtype=t, offset=base + b, count=(e - b) // np.dtype(t).itemsize)
        W[k] = a.reshape(m["shape"]).astype(np.float32)
    return W


def export(model: str, seq_len: int, out_path: str, lora=None):
    """Build the MLProgram and save it. `lora` optionally merges adapter deltas
    {name: (A, B, scale)} into the base weights before export (for personal models)."""
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    a = ARCH[model]
    dim, nh, nkv, hd, NL, V, eps, theta = (a["dim"], a["nh"], a["nkv"], a["hd"],
                                           a["nl"], a["vocab"], a["eps"], a["theta"])
    S = seq_len
    W = _load_weights(a["hf"])
    EMB = W["model.embed_tokens.weight"]

    if lora:  # merge LoRA into base weights: W' = W + scale * B @ A
        for name, (A, B, scale) in lora.items():
            if name in W:
                W[name] = W[name] + scale * (B @ A)

    pos = np.arange(S)[:, None]; idx = np.arange(0, hd, 2)[None, :]
    ang = pos * (1.0 / (theta ** (idx / hd)))
    COS = np.cos(ang).astype(np.float32); SIN = np.sin(ang).astype(np.float32)
    MASK = np.triu(np.full((S, S), -1e9, np.float32), 1)
    rep = nh // nkv

    def rmsn(x, w):
        ms = mb.reduce_mean(x=mb.mul(x=x, y=x), axes=[-1], keep_dims=True)
        return mb.mul(x=mb.mul(x=x, y=mb.rsqrt(x=mb.add(x=ms, y=eps))), y=w)

    def rope(t, nheads):
        h2 = hd // 2
        t4 = mb.reshape(x=t, shape=[S, nheads, h2, 2])
        x1 = mb.reshape(x=mb.slice_by_index(x=t4, begin=[0, 0, 0, 0], end=[S, nheads, h2, 1]), shape=[S, nheads, h2])
        x2 = mb.reshape(x=mb.slice_by_index(x=t4, begin=[0, 0, 0, 1], end=[S, nheads, h2, 2]), shape=[S, nheads, h2])
        cs = mb.reshape(x=mb.const(val=COS), shape=[S, 1, h2]); sn = mb.reshape(x=mb.const(val=SIN), shape=[S, 1, h2])
        o1 = mb.sub(x=mb.mul(x=x1, y=cs), y=mb.mul(x=x2, y=sn))
        o2 = mb.add(x=mb.mul(x=x1, y=sn), y=mb.mul(x=x2, y=cs))
        return mb.reshape(x=mb.concat(values=[mb.reshape(x=o1, shape=[S, nheads, h2, 1]),
                                              mb.reshape(x=o2, shape=[S, nheads, h2, 1])], axis=3),
                          shape=[S, nheads, hd])

    @mb.program(input_specs=[mb.TensorSpec(shape=(S, dim))])
    def prog(x):
        for L in range(NL):
            def g(n): return W[f"model.layers.{L}.{n}"]
            h = rmsn(x, g("input_layernorm.weight").reshape(1, dim))
            q = rope(mb.reshape(x=mb.matmul(x=h, y=g("self_attn.q_proj.weight"), transpose_y=True), shape=[S, nh, hd]), nh)
            k = rope(mb.reshape(x=mb.matmul(x=h, y=g("self_attn.k_proj.weight"), transpose_y=True), shape=[S, nkv, hd]), nkv)
            v = mb.reshape(x=mb.matmul(x=h, y=g("self_attn.v_proj.weight"), transpose_y=True), shape=[S, nkv, hd])
            k = mb.reshape(x=mb.tile(x=mb.reshape(x=k, shape=[S, nkv, 1, hd]), reps=[1, 1, rep, 1]), shape=[S, nh, hd])
            v = mb.reshape(x=mb.tile(x=mb.reshape(x=v, shape=[S, nkv, 1, hd]), reps=[1, 1, rep, 1]), shape=[S, nh, hd])
            qh = mb.transpose(x=q, perm=[1, 0, 2]); kh = mb.transpose(x=k, perm=[1, 0, 2]); vh = mb.transpose(x=v, perm=[1, 0, 2])
            sc = mb.add(x=mb.mul(x=mb.matmul(x=qh, y=kh, transpose_y=True), y=1.0 / np.sqrt(hd)),
                        y=mb.reshape(x=mb.const(val=MASK), shape=[1, S, S]))
            o = mb.matmul(x=mb.softmax(x=sc, axis=-1), y=vh)
            o = mb.reshape(x=mb.transpose(x=o, perm=[1, 0, 2]), shape=[S, dim])
            x = mb.add(x=x, y=mb.matmul(x=o, y=g("self_attn.o_proj.weight"), transpose_y=True))
            h = rmsn(x, g("post_attention_layernorm.weight").reshape(1, dim))
            gt = mb.matmul(x=h, y=g("mlp.gate_proj.weight"), transpose_y=True)
            up = mb.matmul(x=h, y=g("mlp.up_proj.weight"), transpose_y=True)
            x = mb.add(x=x, y=mb.matmul(x=mb.mul(x=mb.mul(x=gt, y=mb.sigmoid(x=gt)), y=up),
                                        y=g("mlp.down_proj.weight"), transpose_y=True))
        x = rmsn(x, W["model.norm.weight"].reshape(1, dim))
        return mb.matmul(x=x, y=EMB, transpose_y=True, name="logits")

    m = ct.convert(prog, convert_to="mlprogram", compute_units=ct.ComputeUnit.CPU_AND_NE)
    m.save(out_path)
    return out_path


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="smollm2-135m", choices=list(ARCH))
    p.add_argument("--seq-len", type=int, default=32)
    p.add_argument("--out", required=True)
    args = p.parse_args()
    print("exported:", export(args.model, args.seq_len, args.out))
