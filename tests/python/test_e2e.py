"""End-to-end tests: create -> learn -> chat -> export full workflow."""

import json
import shutil
import pytest
from pathlib import Path

from aneforge.personal import PersonalModel, MODELS_DIR


@pytest.fixture
def e2e_model():
    """Create and clean up an e2e test model."""
    name = "_e2e_test_model"
    model_dir = MODELS_DIR / name
    if model_dir.exists():
        shutil.rmtree(model_dir)
    yield name
    if model_dir.exists():
        shutil.rmtree(model_dir)


@pytest.fixture
def training_data(tmp_path):
    """Create training data files."""
    txt = tmp_path / "notes.txt"
    txt.write_text(
        "Machine learning is a subset of artificial intelligence.\n\n"
        "Neural networks are inspired by the human brain.\n\n"
        "Deep learning uses multiple layers of neural networks.\n\n"
        "Training involves adjusting weights to minimize loss.\n\n"
        "The Apple Neural Engine accelerates ML inference.\n\n"
    )

    jsonl = tmp_path / "data.jsonl"
    lines = [
        json.dumps({"text": "ANEForge trains models on the Apple Neural Engine."}),
        json.dumps({"text": "LoRA adapters enable efficient fine-tuning."}),
        json.dumps({"text": "The M5 chip has 38 TOPS of ANE compute."}),
    ]
    jsonl.write_text("\n".join(lines))

    return {"txt": str(txt), "jsonl": str(jsonl)}


def test_full_workflow(e2e_model, training_data, tmp_path):
    """Test the complete create -> learn -> learn -> export workflow."""

    # 1. Create personal model
    model = PersonalModel.create(e2e_model, base="smollm2-135m", description="E2E test")
    assert model.path.exists()
    assert model.info()["version"] == 0

    # 2. First learning session (txt data)
    model.learn(training_data["txt"], epochs=1)
    info = model.info()
    assert info["version"] == 1
    assert info["total_steps"] > 0

    # 3. Second learning session (jsonl data) — incremental
    model.learn(training_data["jsonl"], epochs=1)
    info = model.info()
    assert info["version"] == 2
    assert info["sessions"] == 2

    # 4. Check versions exist
    versions = sorted(model.versions_dir.iterdir())
    assert len(versions) == 2

    # 5. Export as safetensors
    from aneforge.export import export_model
    export_path = tmp_path / "exported.safetensors"
    result = export_model(str(versions[-1]), "safetensors", str(export_path))
    assert Path(result).exists()

    # 6. Export as GGUF
    gguf_path = tmp_path / "exported.gguf"
    result = export_model(str(versions[-1]), "gguf", str(gguf_path))
    assert Path(result).exists()

    # 7. Chat session
    from aneforge.chat import ChatSession
    session = ChatSession(model_name="smollm2-135m", max_tokens=10)
    response = session.generate("Hello!")
    assert isinstance(response, str)
    assert len(session.history) == 2

    # 8. Model info is complete
    model.print_info()
    info = model.info()
    assert info["name"] == e2e_model
    assert info["base"] == "smollm2-135m"
    assert info["version"] == 2

    # 9. Clean up
    model.delete(confirm=True)
    assert not model.path.exists()


def test_trainer_with_native_backend(training_data, tmp_path):
    """Test Trainer class with the native Rust backend."""
    from aneforge.trainer import Trainer
    from aneforge.config import ANEConfig

    config = ANEConfig(backend="cpu", seq_len=32, log_every=5)
    trainer = Trainer("smollm2-135m", config=config, verbose=False)
    trainer.load_data(training_data["txt"])
    losses = trainer.train(steps=10)

    assert len(losses) == 10
    assert trainer.step == 10

    # Save
    out = tmp_path / "output"
    trainer.save(str(out))
    assert (out / "adapter_config.json").exists()

    # Export
    from aneforge.export import export_model
    sf_path = tmp_path / "model.safetensors"
    export_model(str(out), "safetensors", str(sf_path))
    assert sf_path.with_suffix(".safetensors").exists()
