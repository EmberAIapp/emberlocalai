"""Tests for model registry and loading."""

import pytest
from aneforge.model import (
    MODEL_REGISTRY,
    MODEL_ALIASES,
    resolve_model_name,
    get_hf_model_id,
    get_model_info,
)


def test_model_registry_not_empty():
    assert len(MODEL_REGISTRY) > 0


def test_known_models_in_registry():
    expected = ["smollm2-135m", "qwen2.5-0.5b", "llama-3.2-1b", "phi-3-mini", "gemma-2-2b"]
    for model in expected:
        assert model in MODEL_REGISTRY, f"{model} not in registry"


def test_resolve_direct_name():
    assert resolve_model_name("smollm2-135m") == "smollm2-135m"
    assert resolve_model_name("qwen2.5-0.5b") == "qwen2.5-0.5b"


def test_resolve_alias():
    assert resolve_model_name("smollm2") == "smollm2-135m"
    assert resolve_model_name("smollm") == "smollm2-135m"
    assert resolve_model_name("qwen") == "qwen2.5-0.5b"
    assert resolve_model_name("llama") == "llama-3.2-1b"


def test_resolve_case_insensitive():
    assert resolve_model_name("SmolLM2-135M") == "smollm2-135m"
    assert resolve_model_name("SMOLLM2-135M") == "smollm2-135m"


def test_resolve_hf_id():
    result = resolve_model_name("HuggingFaceTB/SmolLM2-135M")
    assert result == "smollm2-135m"


def test_resolve_unknown_returns_as_is():
    assert resolve_model_name("some/custom-model") == "some/custom-model"


def test_get_hf_model_id():
    assert get_hf_model_id("smollm2-135m") == "HuggingFaceTB/SmolLM2-135M"
    assert get_hf_model_id("qwen2.5-0.5b") == "Qwen/Qwen2.5-0.5B"


def test_get_model_info():
    info = get_model_info("smollm2-135m")
    assert info["params"] == "135M"
    assert info["layers"] == 30
    assert info["dim"] == 576

    info = get_model_info("llama-3.2-1b")
    assert info["params"] == "1.2B"
    assert info["layers"] == 16
