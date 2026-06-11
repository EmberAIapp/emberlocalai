"""Shared loader: HuggingFace weights -> native Rust engine.

Centralizes the HF->Rust tensor mapping (including GQA expansion) so both the
trainer and the chat/inference path use exactly the same weight layout.
"""

from __future__ import annotations


def load_native_weights(native, model_name: str, verbose: bool = True) -> int:
    """Load HuggingFace weights into a native PyTrainer.

    The Rust forward pass uses full-rank K/V matrices, so GQA weights
    (n_kv_heads < n_heads) are expanded by repeating each KV head.

    Returns the number of transformer layers loaded.
    """
    import numpy as np
    from aneforge.model import load_model_weights
    from aneforge._core import PyModelConfig

    hf = load_model_weights(model_name)
    if not hf:
        raise RuntimeError(f"No weights available for {model_name}")

    cfg = PyModelConfig(model_name)
    head_dim = cfg.dim // cfg.n_heads

    def send(name: str, arr) -> None:
        native.set_tensor(name, np.ascontiguousarray(arr, dtype=np.float32).tobytes())

    def expand_kv(arr, dim: int):
        # [n_kv * head_dim, in_dim] -> [n_heads * head_dim, in_dim]
        kv_dim = arr.shape[0]
        if kv_dim == dim:
            return arr
        n_rep = dim // kv_dim
        n_kv = kv_dim // head_dim
        return np.repeat(arr.reshape(n_kv, head_dim, -1), n_rep, axis=0).reshape(dim, -1)

    embed = hf["model.embed_tokens.weight"]
    dim = embed.shape[1]
    send("token_embedding", embed)
    send("classifier", hf.get("lm_head.weight", embed))  # tied lm_head
    send("rms_final", hf["model.norm.weight"])

    layer = 0
    while f"model.layers.{layer}.self_attn.q_proj.weight" in hf:
        p = f"model.layers.{layer}"
        send(f"wq.{layer}", hf[f"{p}.self_attn.q_proj.weight"])
        send(f"wk.{layer}", expand_kv(hf[f"{p}.self_attn.k_proj.weight"], dim))
        send(f"wv.{layer}", expand_kv(hf[f"{p}.self_attn.v_proj.weight"], dim))
        send(f"wo.{layer}", hf[f"{p}.self_attn.o_proj.weight"])
        send(f"w1.{layer}", hf[f"{p}.mlp.gate_proj.weight"])
        send(f"w2.{layer}", hf[f"{p}.mlp.down_proj.weight"])
        send(f"w3.{layer}", hf[f"{p}.mlp.up_proj.weight"])
        send(f"rms_att.{layer}", hf[f"{p}.input_layernorm.weight"])
        send(f"rms_ffn.{layer}", hf[f"{p}.post_attention_layernorm.weight"])
        layer += 1

    if verbose:
        print(f"Loaded {layer} layers of real weights into native engine")
    return layer


def save_lora(native, path) -> int:
    """Persist trained LoRA adapters from the native engine to disk (.npz).

    Returns the number of adapters saved.
    """
    import numpy as np
    from pathlib import Path

    adapters = native.get_lora()
    if not adapters:
        return 0

    arrays = {}
    meta = {}
    for name, in_dim, out_dim, rank, a_bytes, b_bytes in adapters:
        a = np.frombuffer(a_bytes, dtype=np.float32).copy()
        b = np.frombuffer(b_bytes, dtype=np.float32).copy()
        arrays[f"{name}::a"] = a
        arrays[f"{name}::b"] = b
        meta[name] = [in_dim, out_dim, rank]

    out = Path(path) / "adapter.npz"
    np.savez(out, **arrays)
    return len(meta)


def load_lora(native, path) -> int:
    """Load trained LoRA adapters from disk into the native engine.

    Returns the number of adapters loaded (0 if none found).
    """
    import numpy as np
    from pathlib import Path

    npz = Path(path) / "adapter.npz"
    if not npz.exists():
        return 0

    data = np.load(npz)
    names = sorted({k.split("::")[0] for k in data.files})
    count = 0
    for name in names:
        a = np.ascontiguousarray(data[f"{name}::a"], dtype=np.float32)
        b = np.ascontiguousarray(data[f"{name}::b"], dtype=np.float32)
        native.set_lora(name, a.tobytes(), b.tobytes())
        count += 1
    return count
