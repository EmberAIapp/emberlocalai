"""Model loading and weight management."""

from pathlib import Path
from typing import Optional

# Registry of known models with their HuggingFace identifiers
MODEL_REGISTRY = {
    # SmolLM2 — Instruct variants (chat-tuned) are the default for conversation
    "smollm2-135m-instruct": "HuggingFaceTB/SmolLM2-135M-Instruct",
    "smollm2-360m-instruct": "HuggingFaceTB/SmolLM2-360M-Instruct",
    "smollm2-1.7b-instruct": "HuggingFaceTB/SmolLM2-1.7B-Instruct",
    # SmolLM2 base (completion) variants
    "smollm2-135m": "HuggingFaceTB/SmolLM2-135M",
    "smollm2-360m": "HuggingFaceTB/SmolLM2-360M",
    "smollm2-1.7b": "HuggingFaceTB/SmolLM2-1.7B",

    # Qwen family
    "qwen2.5-0.5b": "Qwen/Qwen2.5-0.5B",
    "qwen2.5-1.5b": "Qwen/Qwen2.5-1.5B",

    # Phi family
    "phi-3-mini": "microsoft/Phi-3-mini-4k-instruct",

    # Llama family
    "tinyllama": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "llama-3.2-1b": "meta-llama/Llama-3.2-1B",

    # Gemma family
    "gemma-2-2b": "google/gemma-2-2b",
}

# Short aliases for convenience
MODEL_ALIASES = {
    "smollm2": "smollm2-135m",
    "smollm": "smollm2-135m",
    "qwen": "qwen2.5-0.5b",
    "phi": "phi-3-mini",
    "llama": "llama-3.2-1b",
    "tinyllama": "tinyllama",
    "gemma": "gemma-2-2b",
}


def resolve_model_name(name: str) -> str:
    """Resolve a model name or alias to the canonical name."""
    lower = name.lower().strip()

    # Check direct match
    if lower in MODEL_REGISTRY:
        return lower

    # Check aliases
    if lower in MODEL_ALIASES:
        return MODEL_ALIASES[lower]

    # Check if it's a HuggingFace model ID
    if "/" in name:
        # Try to find in registry by HF ID
        for key, hf_id in MODEL_REGISTRY.items():
            if hf_id.lower() == name.lower():
                return key
        # Unknown HF model - return as-is
        return name

    # Fuzzy match
    for key in MODEL_REGISTRY:
        if lower in key or key in lower:
            return key

    # Default: return as-is (user may provide custom HF model)
    return name


def get_hf_model_id(name: str) -> str:
    """Get the HuggingFace model ID for a given model name."""
    canonical = resolve_model_name(name)
    return MODEL_REGISTRY.get(canonical, canonical)


def load_model_weights(
    model_name: str,
    cache_dir: Optional[str] = None,
) -> dict:
    """
    Download and load model weights from HuggingFace.

    Returns a dict of weight name -> numpy array.
    """
    hf_id = get_hf_model_id(model_name)
    cache = Path(cache_dir) if cache_dir else Path.home() / ".cache" / "aneforge" / "models"
    cache.mkdir(parents=True, exist_ok=True)

    model_dir = cache / hf_id.replace("/", "--")

    if model_dir.exists() and any(model_dir.glob("*.safetensors")):
        print(f"Loading cached model from {model_dir}")
        return _load_safetensors(model_dir)

    print(f"Downloading {hf_id} from HuggingFace...")
    try:
        from huggingface_hub import snapshot_download
        local_dir = snapshot_download(
            hf_id,
            local_dir=str(model_dir),
            allow_patterns=["*.safetensors", "config.json", "tokenizer*"],
        )
        return _load_safetensors(Path(local_dir))
    except ImportError:
        print("huggingface_hub not installed. Install with: pip install huggingface_hub")
        return {}
    except Exception as e:
        print(f"Download failed: {e}")
        print(f"Using random weights for testing")
        return {}


def _load_safetensors(model_dir: Path) -> dict:
    """Load weights from safetensors files."""
    weights = {}
    try:
        import json
        import numpy as np
        import ml_dtypes  # registers bfloat16 for numpy

        _DTYPES = {
            "F32": np.float32, "F16": np.float16, "BF16": ml_dtypes.bfloat16,
            "F64": np.float64, "I64": np.int64, "I32": np.int32,
        }
        # Parse safetensors manually: numpy's safe_open rejects bfloat16
        for path in sorted(model_dir.glob("*.safetensors")):
            raw = path.read_bytes()
            header_len = int.from_bytes(raw[:8], "little")
            header = json.loads(raw[8:8 + header_len])
            data_start = 8 + header_len
            for key, meta in header.items():
                if key == "__metadata__":
                    continue
                dtype = _DTYPES[meta["dtype"]]
                begin, end = meta["data_offsets"]
                arr = np.frombuffer(raw, dtype=dtype, offset=data_start + begin,
                                    count=(end - begin) // np.dtype(dtype).itemsize)
                weights[key] = arr.reshape(meta["shape"]).astype(np.float32)
    except ImportError:
        print("safetensors not installed. Install with: pip install safetensors")
    return weights


def get_model_info(name: str) -> dict:
    """Get model information without downloading."""
    canonical = resolve_model_name(name)
    hf_id = get_hf_model_id(name)

    # Model config data
    configs = {
        "smollm2-135m": {"params": "135M", "layers": 30, "dim": 576, "type": "causal-lm"},
        "smollm2-135m-instruct": {"params": "135M", "layers": 30, "dim": 576, "type": "chat"},
        "smollm2-360m": {"params": "360M", "layers": 32, "dim": 960, "type": "causal-lm"},
        "smollm2-360m-instruct": {"params": "360M", "layers": 32, "dim": 960, "type": "chat"},
        "qwen2.5-0.5b": {"params": "500M", "layers": 24, "dim": 896, "type": "causal-lm"},
        "phi-3-mini": {"params": "3.8B", "layers": 32, "dim": 3072, "type": "causal-lm"},
        "tinyllama": {"params": "1.1B", "layers": 22, "dim": 2048, "type": "causal-lm"},
        "llama-3.2-1b": {"params": "1.2B", "layers": 16, "dim": 2048, "type": "causal-lm"},
        "gemma-2-2b": {"params": "2.6B", "layers": 26, "dim": 2304, "type": "causal-lm"},
    }

    info = configs.get(canonical, {"params": "unknown"})
    info["name"] = canonical
    info["hf_id"] = hf_id
    return info
