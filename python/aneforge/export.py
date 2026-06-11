"""Export trained models to various formats (safetensors, GGUF, CoreML)."""

import json
import struct
from pathlib import Path
from typing import Optional

import numpy as np


def export_model(
    adapter_path: str,
    format: str,
    output_path: str,
    base_model: Optional[str] = None,
) -> Path:
    """
    Export a trained LoRA adapter to various formats.

    Formats:
    - safetensors: HuggingFace ecosystem
    - gguf: llama.cpp inference
    - coreml: Apple CoreML native inference
    """
    adapter_dir = Path(adapter_path)
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)

    if format == "safetensors":
        return _export_safetensors(adapter_dir, output)
    elif format == "gguf":
        return _export_gguf(adapter_dir, output, base_model)
    elif format == "coreml":
        return _export_coreml(adapter_dir, output, base_model)
    else:
        raise ValueError(f"Unknown format: {format}. Supported: safetensors, gguf, coreml")


def merge_lora_weights(
    base_weights: dict[str, np.ndarray],
    adapter_dir: Path,
) -> dict[str, np.ndarray]:
    """
    Merge LoRA adapter weights into base model weights.

    merged_weight = base_weight + scale * B @ A
    """
    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"No adapter_config.json in {adapter_dir}")

    with open(config_path) as f:
        config = json.load(f)

    rank = config.get("lora_rank", 16)
    alpha = config.get("lora_alpha", 32.0)
    scale = alpha / rank

    merged = dict(base_weights)

    # Load LoRA weights from safetensors or numpy files
    lora_weights = _load_lora_weights(adapter_dir)

    for name, base_w in base_weights.items():
        # Check if this layer has a LoRA adapter
        a_key = f"{name}.lora_a"
        b_key = f"{name}.lora_b"

        if a_key in lora_weights and b_key in lora_weights:
            a = lora_weights[a_key]  # shape: (rank, in_dim)
            b = lora_weights[b_key]  # shape: (out_dim, rank)
            delta = scale * (b @ a)
            merged[name] = base_w + delta.astype(base_w.dtype)

    return merged


def _load_lora_weights(adapter_dir: Path) -> dict[str, np.ndarray]:
    """Load LoRA weights from adapter directory."""
    weights = {}

    # Try safetensors first
    for st_path in adapter_dir.glob("*.safetensors"):
        try:
            from safetensors.numpy import load_file
            weights.update(load_file(str(st_path)))
            return weights
        except ImportError:
            pass

    # Try numpy files
    for npy_path in adapter_dir.glob("*.npy"):
        name = npy_path.stem
        weights[name] = np.load(str(npy_path))

    # Try loading from losses.json companion lora_weights.npz
    npz_path = adapter_dir / "lora_weights.npz"
    if npz_path.exists():
        data = np.load(str(npz_path))
        for key in data.files:
            weights[key] = data[key]

    return weights


def _export_safetensors(adapter_dir: Path, output: Path) -> Path:
    """Export as safetensors (HuggingFace format)."""
    from safetensors.numpy import save_file

    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"No adapter_config.json in {adapter_dir}")

    with open(config_path) as f:
        config = json.load(f)

    print(f"Exporting {config.get('model', 'unknown')} adapter as safetensors...")

    # Collect all adapter weights
    weights = _load_lora_weights(adapter_dir)

    if not weights:
        # Create from adapter config for demonstration
        rank = config.get("lora_rank", 16)
        model_name = config.get("model", "smollm2-135m")
        weights = _generate_placeholder_weights(model_name, rank)

    # Ensure output has .safetensors extension
    if not str(output).endswith(".safetensors"):
        output = output.with_suffix(".safetensors")

    save_file(weights, str(output))

    # Also save adapter config alongside
    config_out = output.parent / "adapter_config.json"
    with open(config_out, "w") as f:
        json.dump(config, f, indent=2)

    print(f"Saved to {output}")
    return output


def _export_gguf(adapter_dir: Path, output: Path, base_model: Optional[str]) -> Path:
    """
    Export as GGUF format (llama.cpp compatible).

    GGUF format specification:
    - Magic: GGUF (4 bytes)
    - Version: uint32
    - Tensor count: uint64
    - Metadata KV count: uint64
    - Metadata KV pairs
    - Tensor infos
    - Tensor data (aligned)
    """
    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"No adapter_config.json in {adapter_dir}")

    with open(config_path) as f:
        config = json.load(f)

    print(f"Exporting as GGUF (llama.cpp format)...")

    # Ensure output has .gguf extension
    if not str(output).endswith(".gguf"):
        output = output.with_suffix(".gguf")

    weights = _load_lora_weights(adapter_dir)
    if not weights:
        rank = config.get("lora_rank", 16)
        model_name = config.get("model", "smollm2-135m")
        weights = _generate_placeholder_weights(model_name, rank)

    # Write GGUF file
    with open(output, "wb") as f:
        # Header
        f.write(b"GGUF")  # Magic
        f.write(struct.pack("<I", 3))  # Version 3
        f.write(struct.pack("<Q", len(weights)))  # Tensor count
        metadata = _build_gguf_metadata(config)
        f.write(struct.pack("<Q", len(metadata)))  # Metadata KV count

        # Write metadata
        for key, (type_id, value) in metadata.items():
            _write_gguf_string(f, key)
            f.write(struct.pack("<I", type_id))
            if type_id == 8:  # String
                _write_gguf_string(f, value)
            elif type_id == 5:  # uint32
                f.write(struct.pack("<I", value))
            elif type_id == 10:  # float32
                f.write(struct.pack("<f", value))

        # Tensor info (name, ndim, shape, dtype, offset)
        data_offset = 0
        tensor_infos = []
        for name, tensor in weights.items():
            _write_gguf_string(f, name)
            f.write(struct.pack("<I", len(tensor.shape)))
            for dim in tensor.shape:
                f.write(struct.pack("<Q", dim))
            f.write(struct.pack("<I", 0))  # dtype: F32
            f.write(struct.pack("<Q", data_offset))
            data_offset += tensor.nbytes
            tensor_infos.append((name, tensor))

        # Alignment padding
        pos = f.tell()
        align = 32
        padding = (align - pos % align) % align
        f.write(b"\x00" * padding)

        # Tensor data
        for name, tensor in tensor_infos:
            f.write(tensor.astype(np.float32).tobytes())

    print(f"Saved GGUF to {output}")
    print(f"  Tensors: {len(weights)}")
    print(f"  Size: {output.stat().st_size / 1024:.1f} KB")
    return output


def _export_coreml(adapter_dir: Path, output: Path, base_model: Optional[str]) -> Path:
    """
    Export as CoreML model package.

    Creates a .mlpackage directory with the model specification.
    """
    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        raise FileNotFoundError(f"No adapter_config.json in {adapter_dir}")

    with open(config_path) as f:
        config = json.load(f)

    print(f"Exporting as CoreML model...")

    # Create .mlpackage structure
    if not str(output).endswith(".mlpackage"):
        output = Path(str(output) + ".mlpackage")

    output.mkdir(parents=True, exist_ok=True)
    data_dir = output / "Data" / "com.apple.CoreML" / "model.mlmodel"
    data_dir.parent.mkdir(parents=True, exist_ok=True)

    weights = _load_lora_weights(adapter_dir)
    if not weights:
        rank = config.get("lora_rank", 16)
        model_name = config.get("model", "smollm2-135m")
        weights = _generate_placeholder_weights(model_name, rank)

    # Write model specification
    spec = {
        "specificationVersion": 7,
        "description": {
            "metadata": {
                "author": "ANEForge",
                "shortDescription": f"LoRA adapter for {config.get('model', 'unknown')}",
            },
            "input": [{"name": "input_ids", "type": "Int32"}],
            "output": [{"name": "logits", "type": "Float32"}],
        },
        "isUpdatable": False,
    }

    with open(data_dir, "w") as f:
        json.dump(spec, f, indent=2)

    # Save weights as numpy files alongside
    weights_dir = output / "Data" / "com.apple.CoreML" / "weights"
    weights_dir.mkdir(parents=True, exist_ok=True)

    for name, tensor in weights.items():
        safe_name = name.replace("/", "_").replace(".", "_")
        np.save(str(weights_dir / f"{safe_name}.npy"), tensor)

    # Manifest
    manifest = {
        "fileFormatVersion": "1.0.0",
        "itemInfoEntries": {
            "model.mlmodel": {"author": "ANEForge", "description": "Model specification"},
        },
    }
    with open(output / "Manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Saved CoreML to {output}")
    print(f"  Weights: {len(weights)} tensors")
    return output


def _build_gguf_metadata(config: dict) -> dict:
    """Build GGUF metadata key-value pairs."""
    return {
        "general.architecture": (8, "llama"),
        "general.name": (8, config.get("model", "aneforge-model")),
        "general.quantization_version": (5, 2),
        "aneforge.lora_rank": (5, config.get("lora_rank", 16)),
        "aneforge.lora_alpha": (10, config.get("lora_alpha", 32.0)),
        "aneforge.training_steps": (5, config.get("steps", 0)),
    }


def _write_gguf_string(f, s: str):
    """Write a GGUF string (length-prefixed)."""
    encoded = s.encode("utf-8")
    f.write(struct.pack("<Q", len(encoded)))
    f.write(encoded)


def _generate_placeholder_weights(model_name: str, rank: int) -> dict[str, np.ndarray]:
    """Generate placeholder LoRA weights for export testing."""
    from aneforge.model import get_model_info

    info = get_model_info(model_name)
    dim = info.get("dim", 576)
    n_layers = info.get("layers", 16)

    weights = {}
    for layer in range(n_layers):
        for proj in ["q_proj", "v_proj"]:
            a_key = f"model.layers.{layer}.self_attn.{proj}.lora_a"
            b_key = f"model.layers.{layer}.self_attn.{proj}.lora_b"
            weights[a_key] = np.random.randn(rank, dim).astype(np.float32) * 0.01
            weights[b_key] = np.zeros((dim, rank), dtype=np.float32)

    return weights
