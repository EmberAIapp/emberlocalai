"""Tests for chat interface."""

import pytest
from aneforge.chat import ChatSession


def test_chat_session_init():
    session = ChatSession("smollm2-135m")
    assert session.model_name == "smollm2-135m"
    assert session.temperature == 0.7
    assert session.history == []


def test_generate():
    session = ChatSession("smollm2-135m", max_tokens=20)
    response = session.generate("Hello!")
    assert isinstance(response, str)
    assert len(response) > 0


def test_history_tracked():
    session = ChatSession("smollm2-135m", max_tokens=10)
    session.generate("Hello!")
    assert len(session.history) == 2
    assert session.history[0]["role"] == "user"
    assert session.history[1]["role"] == "assistant"


def test_clear_history():
    session = ChatSession("smollm2-135m", max_tokens=10)
    session.generate("Hello!")
    assert len(session.history) == 2
    session.clear_history()
    assert len(session.history) == 0


def test_system_prompt():
    session = ChatSession("smollm2-135m", system_prompt="You are a helpful assistant.")
    assert session.system_prompt == "You are a helpful assistant."


def test_stream():
    session = ChatSession("smollm2-135m", max_tokens=10)
    parts = list(session.stream("Test"))
    assert len(parts) > 0
    # Each part should be longer or equal to previous
    for i in range(1, len(parts)):
        assert len(parts[i]) >= len(parts[i-1])
