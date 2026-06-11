"""Tests for model export."""

import json
import pytest
from pathlib import Path

from aneforge.export import export_model, _generate_placeholder_weights


@pytest.fixture
def adapter_dir(tmp_path):
    """Create a mock adapter directory."""
    adapter = tmp_path / "adapter"
    adapter.mkdir()

    config = {
        "model": "smollm2-135m",
        "lora_rank": 8,
        "lora_alpha": 16.0,
        "target_modules": ["q_proj", "v_proj"],
        "steps": 10,
        "final_loss": 5.0,
    }
    with open(adapter / "adapter_config.json", "w") as f:
        json.dump(config, f)

    return adapter


def test_export_safetensors(adapter_dir, tmp_path):
    output = tmp_path / "model.safetensors"
    result = export_model(str(adapter_dir), "safetensors", str(output))
    assert Path(result).exists()
    assert str(result).endswith(".safetensors")


def test_export_gguf(adapter_dir, tmp_path):
    output = tmp_path / "model.gguf"
    result = export_model(str(adapter_dir), "gguf", str(output))
    assert Path(result).exists()
    assert str(result).endswith(".gguf")

    # Verify GGUF header
    with open(result, "rb") as f:
        magic = f.read(4)
        assert magic == b"GGUF"


def test_export_coreml(adapter_dir, tmp_path):
    output = tmp_path / "model"
    result = export_model(str(adapter_dir), "coreml", str(output))
    assert Path(result).exists()
    assert str(result).endswith(".mlpackage")
    # Should have Manifest.json
    assert (Path(result) / "Manifest.json").exists()


def test_export_unknown_format(adapter_dir, tmp_path):
    with pytest.raises(ValueError, match="Unknown format"):
        export_model(str(adapter_dir), "unknown", str(tmp_path / "out"))


def test_generate_placeholder_weights():
    weights = _generate_placeholder_weights("smollm2-135m", rank=8)
    assert len(weights) > 0
    # Should have lora_a and lora_b for each layer
    a_keys = [k for k in weights if "lora_a" in k]
    b_keys = [k for k in weights if "lora_b" in k]
    assert len(a_keys) == len(b_keys)
    assert len(a_keys) > 0
