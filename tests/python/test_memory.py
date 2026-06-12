"""Tests for the editable personal-fact memory (the 'it knows me' layer)."""

import tempfile
from pathlib import Path

import pytest

from aneforge.memory import FactStore


@pytest.fixture
def store():
    d = tempfile.mkdtemp()
    return FactStore(Path(d) / "memory.db")


def test_explicit_remember(store):
    f = store.add("My dog is named Pixel", kind="misc", source="explicit")
    assert f is not None
    assert "Pixel" in f.text
    assert len(store.all()) == 1


def test_duplicate_facts_ignored(store):
    store.add("The user lives in Lyon.")
    store.add("The user lives in Lyon.")
    assert len(store.all()) == 1


def test_heuristic_extraction_english(store):
    got = store.extract_and_store("My name is Alex and I work as a baker")
    texts = [f.text for f in got]
    assert "The user's name is Alex." in texts
    assert "The user works as baker." in texts
    # 'and' must NOT be captured into the name (re.I [A-Z] pitfall)
    assert not any("and" in t.lower().split("is ")[-1] for t in texts if "name" in t.lower())


def test_heuristic_extraction_pet(store):
    got = store.extract_and_store("I have a dog named Pixel")
    assert any("dog named Pixel" in f.text for f in got)


def test_heuristic_extraction_french(store):
    got = store.extract_and_store("Je m'appelle Marie et j'habite à Paris")
    texts = [f.text for f in got]
    assert "The user's name is Marie." in texts
    assert "The user lives in Paris." in texts


def test_remember_directive(store):
    got = store.extract_and_store("remember that I prefer short answers")
    assert len(got) == 1
    assert "short answers" in got[0].text


def test_retrieval_is_relevant(store):
    store.extract_and_store("My name is Alex")
    store.extract_and_store("I have a dog named Pixel")
    store.extract_and_store("My favorite color is green")
    hits = store.relevant("what is my dog called?")
    assert hits
    assert any("Pixel" in f.text for f in hits)


def test_forget(store):
    f = store.add("The user lives in Lyon.")
    assert store.delete(f.id) is True
    assert len(store.all()) == 0
    assert store.delete(999) is False


def test_clear(store):
    store.add("fact one")
    store.add("fact two")
    assert store.clear() == 2
    assert store.all() == []


def test_summary_empty(store):
    assert store.summary() == ""


def test_summary_lists_facts(store):
    store.add("The user's name is Alex.")
    s = store.summary()
    assert "Alex" in s
