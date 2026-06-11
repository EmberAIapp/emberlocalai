"""Tests for the Trainer class."""

import json
import tempfile
from pathlib import Path

import pytest
from aneforge.trainer import Trainer
from aneforge.config import ANEConfig


@pytest.fixture
def sample_data(tmp_path):
    f = tmp_path / "train.txt"
    text = "This is test training data. " * 100
    f.write_text(text)
    return str(f)


def test_trainer_init():
    trainer = Trainer("smollm2-135m", verbose=False)
    assert trainer.model_name == "smollm2-135m"
    assert trainer.step == 0
    assert trainer.losses == []


def test_trainer_custom_config():
    config = ANEConfig(lora_rank=8, seq_len=64, backend="cpu")
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    assert trainer.config.lora_rank == 8
    assert trainer.config.seq_len == 64


def test_trainer_load_data(sample_data):
    trainer = Trainer("smollm2-135m", verbose=False)
    trainer.load_data(sample_data)
    assert trainer._data_tokens is not None
    assert len(trainer._data_tokens) > 0


def test_trainer_train_cpu(sample_data):
    config = ANEConfig(backend="cpu", seq_len=32, log_every=5)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    trainer.load_data(sample_data)
    losses = trainer.train(steps=10)
    assert len(losses) == 10
    assert all(isinstance(l, float) for l in losses)
    assert trainer.step == 10


def test_trainer_train_with_data_path(sample_data):
    config = ANEConfig(backend="cpu", seq_len=32, log_every=5)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    losses = trainer.train(data_path=sample_data, steps=5)
    assert len(losses) == 5


def test_trainer_save(sample_data, tmp_path):
    config = ANEConfig(backend="cpu", seq_len=32, log_every=5)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    trainer.train(data_path=sample_data, steps=5)

    save_dir = tmp_path / "output"
    trainer.save(str(save_dir))

    assert (save_dir / "adapter_config.json").exists()
    assert (save_dir / "losses.json").exists()

    with open(save_dir / "adapter_config.json") as f:
        config_data = json.load(f)
    assert config_data["model"] == "smollm2-135m"
    assert config_data["steps"] == 5


def test_trainer_small_dataset(tmp_path):
    """Test auto-adjustment of seq_len for small datasets."""
    f = tmp_path / "tiny.txt"
    f.write_text("Hello world")

    config = ANEConfig(backend="cpu", seq_len=1024, log_every=1)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    trainer.load_data(str(f))
    losses = trainer.train(steps=3)
    # Should auto-reduce seq_len
    assert trainer.config.seq_len < 1024
    assert len(losses) == 3


def test_trainer_no_data_raises():
    config = ANEConfig(backend="cpu")
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    with pytest.raises(ValueError, match="No data loaded"):
        trainer.train(steps=5)


def test_trainer_callbacks(sample_data):
    config = ANEConfig(backend="cpu", seq_len=32, log_every=5)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)

    callback_calls = []
    def my_callback(step, loss):
        callback_calls.append((step, loss))

    trainer.train(data_path=sample_data, steps=5, callbacks=[my_callback])
    assert len(callback_calls) == 5
