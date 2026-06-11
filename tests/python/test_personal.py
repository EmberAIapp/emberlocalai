"""Tests for personal model management."""

import pytest
import shutil
from pathlib import Path

from aneforge.personal import PersonalModel, MODELS_DIR


@pytest.fixture
def clean_model():
    """Create and clean up a test model."""
    name = "_test_model_pytest"
    model_dir = MODELS_DIR / name

    # Clean up before
    if model_dir.exists():
        shutil.rmtree(model_dir)

    yield name

    # Clean up after
    if model_dir.exists():
        shutil.rmtree(model_dir)


@pytest.fixture
def sample_data(tmp_path):
    f = tmp_path / "data.txt"
    f.write_text("Training data for testing. " * 50)
    return str(f)


def test_create_model(clean_model):
    model = PersonalModel.create(clean_model, base="smollm2-135m")
    assert model.name == clean_model
    assert model.path.exists()
    assert model.config_path.exists()


def test_create_duplicate_raises(clean_model):
    PersonalModel.create(clean_model, base="smollm2-135m")
    with pytest.raises(ValueError, match="already exists"):
        PersonalModel.create(clean_model, base="smollm2-135m")


def test_load_model(clean_model):
    PersonalModel.create(clean_model, base="smollm2-135m")
    model = PersonalModel(clean_model)
    assert model.name == clean_model


def test_load_nonexistent_raises():
    with pytest.raises(ValueError, match="not found"):
        PersonalModel("_nonexistent_model_xyz")


def test_model_info(clean_model):
    PersonalModel.create(clean_model, base="smollm2-135m")
    model = PersonalModel(clean_model)
    info = model.info()
    assert info["name"] == clean_model
    assert info["base"] == "smollm2-135m"
    assert info["version"] == 0
    assert info["total_steps"] == 0


def test_learn_creates_version(clean_model, sample_data):
    PersonalModel.create(clean_model, base="smollm2-135m")
    model = PersonalModel(clean_model)

    model.learn(sample_data, epochs=1)

    info = model.info()
    assert info["version"] == 1
    assert info["total_steps"] > 0
    assert info["sessions"] == 1


def test_incremental_learning(clean_model, sample_data):
    PersonalModel.create(clean_model, base="smollm2-135m")
    model = PersonalModel(clean_model)

    model.learn(sample_data, epochs=1)
    model.learn(sample_data, epochs=1)

    info = model.info()
    assert info["version"] == 2
    assert info["sessions"] == 2


def test_list_models(clean_model):
    PersonalModel.create(clean_model, base="smollm2-135m")
    models = PersonalModel.list_models()
    names = [m["name"] for m in models]
    assert clean_model in names


def test_delete_model(clean_model):
    PersonalModel.create(clean_model, base="smollm2-135m")
    model = PersonalModel(clean_model)

    # Without confirm should not delete
    model.delete(confirm=False)
    assert model.path.exists()

    # With confirm should delete
    model.delete(confirm=True)
    assert not model.path.exists()
