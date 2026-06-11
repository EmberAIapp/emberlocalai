"""Tests for data loading and tokenization."""

import json
import tempfile
from pathlib import Path

import pytest
from aneforge.data import (
    load_data,
    tokenize_text,
    _detect_format,
    _simple_tokenize,
    _load_txt,
    _load_jsonl,
    _load_chat,
    _load_csv,
)


@pytest.fixture
def txt_file(tmp_path):
    f = tmp_path / "data.txt"
    f.write_text("Hello world.\n\nThis is a test.\n\nThird paragraph.")
    return str(f)


@pytest.fixture
def jsonl_file(tmp_path):
    f = tmp_path / "data.jsonl"
    lines = [
        json.dumps({"text": "First sample"}),
        json.dumps({"text": "Second sample"}),
        json.dumps({"content": "Third sample"}),
    ]
    f.write_text("\n".join(lines))
    return str(f)


@pytest.fixture
def chat_file(tmp_path):
    f = tmp_path / "chat.jsonl"
    lines = [
        json.dumps({"messages": [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi there!"},
        ]}),
        json.dumps({"messages": [
            {"role": "user", "content": "How are you?"},
            {"role": "assistant", "content": "I'm fine!"},
        ]}),
    ]
    f.write_text("\n".join(lines))
    return str(f)


@pytest.fixture
def csv_file(tmp_path):
    f = tmp_path / "data.csv"
    f.write_text("text,label\nHello world,pos\nGoodbye world,neg\n")
    return str(f)


def test_simple_tokenize():
    tokens = _simple_tokenize("hello")
    assert len(tokens) == 5  # 'h', 'e', 'l', 'l', 'o'
    assert all(isinstance(t, int) for t in tokens)


def test_detect_format_txt():
    assert _detect_format(Path("test.txt")) == "txt"


def test_detect_format_jsonl(tmp_path):
    # _detect_format for .jsonl tries to open the file to check for chat format
    f = tmp_path / "test.jsonl"
    f.write_text('{"text": "hello"}\n')
    assert _detect_format(f) == "jsonl"


def test_detect_format_csv():
    assert _detect_format(Path("test.csv")) == "csv"


def test_load_txt(txt_file):
    tokens = load_data(txt_file, format="txt")
    assert len(tokens) > 0
    assert all(isinstance(t, int) for t in tokens)


def test_load_jsonl(jsonl_file):
    tokens = load_data(jsonl_file, format="jsonl")
    assert len(tokens) > 0


def test_load_chat(chat_file):
    tokens = load_data(chat_file, format="chat")
    assert len(tokens) > 0


def test_load_csv(csv_file):
    tokens = load_data(csv_file, format="csv")
    assert len(tokens) > 0


def test_load_auto_detect(txt_file):
    tokens = load_data(txt_file, format="auto")
    assert len(tokens) > 0


def test_max_samples(jsonl_file):
    tokens_all = load_data(jsonl_file, max_samples=None)
    tokens_one = load_data(jsonl_file, max_samples=1)
    # With max_samples=1, fewer tokens
    assert len(tokens_one) <= len(tokens_all)
