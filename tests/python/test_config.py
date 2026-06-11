"""Tests for hardware detection and auto-configuration."""

import pytest
from aneforge.config import ANEConfig, detect_chip, auto_config, CHIP_PRESETS


def test_detect_chip_returns_dict():
    chip = detect_chip()
    assert isinstance(chip, dict)
    assert "chip" in chip
    assert "chip_id" in chip
    assert "memory_gb" in chip
    assert "has_ane" in chip
    assert "variant" in chip


def test_detect_chip_apple_silicon():
    """On Apple Silicon, should detect M-series chip."""
    chip = detect_chip()
    assert chip["chip_id"] >= 1
    assert chip["has_ane"] is True
    assert chip["memory_gb"] > 0
    assert chip["variant"] in ("base", "pro", "max", "ultra")


def test_detect_chip_specs():
    """Should return detailed specs."""
    chip = detect_chip()
    assert "ane_cores" in chip
    assert "gpu_cores" in chip
    assert "gpu_neural_accelerators" in chip
    assert "mem_bandwidth_gbs" in chip
    assert chip["ane_cores"] > 0


def test_ane_config_defaults():
    config = ANEConfig()
    assert config.lora_rank == 16
    assert config.lora_alpha == 32.0
    assert config.backend == "auto"
    assert config.seq_len == 256
    assert config.batch_size == 1
    assert config.learning_rate == 1e-4
    assert "q_proj" in config.target_modules
    assert "v_proj" in config.target_modules


def test_auto_config():
    config = auto_config()
    chip = detect_chip()
    if chip["has_ane"]:
        assert config.backend == "ane"
        assert config.lora_rank > 0
    else:
        assert config.backend == "cpu"


def test_auto_config_with_model():
    config = auto_config("smollm2-135m")
    assert config.lora_rank > 0
    assert config.seq_len > 0


def test_chip_presets_exist():
    """All chip+variant combos should exist."""
    for chip_id in [1, 2, 3, 4, 5]:
        key = (chip_id, "base")
        assert key in CHIP_PRESETS, f"{key} not in CHIP_PRESETS"
        preset = CHIP_PRESETS[key]
        assert "lora_rank" in preset
        assert "batch_size" in preset
        assert "seq_len" in preset
        assert "grad_accum_steps" in preset


def test_chip_presets_pro_max():
    """Pro and Max variants should exist for M1-M5."""
    for chip_id in [1, 2, 3, 4, 5]:
        assert (chip_id, "pro") in CHIP_PRESETS
        assert (chip_id, "max") in CHIP_PRESETS


def test_chip_presets_scale_up():
    """Higher chip generations should have bigger presets."""
    assert CHIP_PRESETS[(5, "base")]["lora_rank"] >= CHIP_PRESETS[(1, "base")]["lora_rank"]
    assert CHIP_PRESETS[(5, "base")]["seq_len"] >= CHIP_PRESETS[(1, "base")]["seq_len"]


def test_chip_presets_max_bigger_than_base():
    """Max variants should have bigger presets than base."""
    for chip_id in [3, 4, 5]:
        base = CHIP_PRESETS[(chip_id, "base")]
        max_v = CHIP_PRESETS[(chip_id, "max")]
        assert max_v["lora_rank"] >= base["lora_rank"]
        assert max_v["batch_size"] >= base["batch_size"]


def test_m5_pro_max_presets():
    """M5 Pro and Max should have highest presets."""
    m5_pro = CHIP_PRESETS[(5, "pro")]
    m5_max = CHIP_PRESETS[(5, "max")]
    assert m5_pro["lora_rank"] == 64
    assert m5_pro["seq_len"] == 2048
    assert m5_max["batch_size"] == 8
