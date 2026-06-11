"""Tests for native Rust/PyO3 bindings."""

import pytest


def test_import_core():
    from aneforge._core import detect_hardware, available_models, version
    assert version() == "0.1.0"


def test_detect_hardware():
    from aneforge._core import detect_hardware
    hw = detect_hardware()
    assert hw.has_ane  # Running on Apple Silicon
    assert hw.memory_gb > 0
    assert hw.ane_cores > 0
    assert hw.peak_tops > 0


def test_available_models():
    from aneforge._core import available_models
    models = available_models()
    assert len(models) > 0
    assert "SmolLM2-135M" in models


def test_model_config():
    from aneforge._core import PyModelConfig
    cfg = PyModelConfig("SmolLM2-135M")
    assert cfg.n_layers == 30
    assert cfg.dim == 576
    assert cfg.vocab_size == 49152
    assert cfg.total_params() > 0


def test_model_config_unknown_raises():
    from aneforge._core import PyModelConfig
    with pytest.raises(ValueError, match="Unknown model"):
        PyModelConfig("nonexistent-model-xyz")


def test_lora_config():
    from aneforge._core import PyLoRAConfig
    lora = PyLoRAConfig(rank=16, alpha=32.0)
    assert lora.rank == 16
    assert lora.alpha == 32.0
    assert lora.scaling() == 2.0
    assert "q_proj" in lora.target_modules


def test_trainer_create():
    from aneforge._core import PyTrainer, PyLoRAConfig
    lora = PyLoRAConfig(rank=4, alpha=8.0)
    trainer = PyTrainer("SmolLM2-135M", lora)
    assert trainer.get_step() == 0


def test_trainer_train():
    from aneforge._core import PyTrainer, PyLoRAConfig
    lora = PyLoRAConfig(rank=4, alpha=8.0)
    trainer = PyTrainer("SmolLM2-135M", lora)

    tokens = list(range(1, 201))
    losses = trainer.train_on_tokens(tokens, steps=2, lr=1e-4, seq_len=32)

    assert len(losses) == 2
    assert all(isinstance(l, float) for l in losses)
    assert trainer.get_step() == 2
    assert trainer.get_loss() > 0
