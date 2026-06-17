"""Editable personal-fact memory for Ember.

The fine-tuned LoRA adapter learns the user's *voice and style*. Discrete *facts*
("my dog is named Pixel", "I work as a baker") belong here instead: in an
explicit, inspectable, editable, deletable store. This is what lets Ember say
"here is what I know about you" — and lets the user correct or forget it.

Design choices:
- One SQLite DB per personal model (`~/.aneforge/models/{name}/memory.db`).
- Fact extraction in the EMBER APP is done by the MODEL (`ember_daemon._extract_facts`),
  so it works in EVERY language (§2.7) and is grounded against the source to block the
  small model's hallucinations. The regex `_PATTERNS` / `extract_and_store` below are
  LEGACY — FR/EN only, used solely by the CLI (`chat.py`), NOT on the app path.
- Categories are assigned by `classify_kind` (multilingual semantic prototypes, no regex).
- 100% local. Nothing leaves the machine.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


@dataclass
class Fact:
    id: int
    kind: str          # name | location | job | preference | relationship | project | misc
    text: str          # human-readable fact, e.g. "The user's dog is named Pixel."
    source: str        # "explicit" | "auto"
    created_at: str

    def __str__(self) -> str:
        return f"[{self.id}] ({self.kind}) {self.text}"


# LEGACY (CLI-only, FR/EN). The Ember app extracts facts with the MODEL (§2.7) — see the
# module docstring. Kept so the standalone CLI (`chat.py`) still works; do not extend it.
# Heuristic extraction patterns. Each maps a regex (case-insensitive) over a user
# message to a (kind, template) pair. {0} is the first captured group.
# NOTE: patterns run with re.I, under which [A-Z] would also match lowercase.
# Where a capital letter is REQUIRED (proper nouns), use (?-i:[A-Z][a-z'-]+) to
# keep the keyword case-insensitive but force the captured token to be Capitalized.
_CAP = r"(?-i:[A-Z][a-z'\-]+)"
_PATTERNS: list[tuple[str, str, str]] = [
    # English
    (rf"\bmy name is ({_CAP}(?:\s+{_CAP})?)", "name", "The user's name is {0}."),
    (r"\bi(?:'m| am) (\d{1,2}) years old", "misc", "The user is {0} years old."),
    (rf"\bi live in ({_CAP}(?:,?\s+{_CAP})?)", "location", "The user lives in {0}."),
    (r"\bi work as (?:an?\s+)?([a-z'-]+(?:\s+[a-z'-]+)?)", "job", "The user works as {0}."),
    (r"\bmy (?:favou?rite )?colou?r is ([a-z'-]+)", "preference", "The user's favorite color is {0}."),
    (rf"\bi have a (dog|cat|pet)(?: named| called) ({_CAP})", "relationship", "The user has a {0} named {1}."),
    (rf"\bmy (dog|cat|pet) is (?:named |called )?({_CAP})", "relationship", "The user's {0} is named {1}."),
    (r"\bi(?:'m| am) working on ([\w'-]+)", "project", "The user is working on {0}."),
    (r"\bi prefer ([a-z'-]+(?:\s+[a-z'-]+){0,4})", "preference", "The user prefers {0}."),
    # French
    (rf"\bje m'appelle ({_CAP}(?:\s+{_CAP})?)", "name", "The user's name is {0}."),
    (rf"\bj'habite (?:à |a |en |au )?({_CAP})", "location", "The user lives in {0}."),
    (r"\bma couleur (?:préférée |preferee )?est (?:le |la )?([a-zà-ÿ'-]+)", "preference", "The user's favorite color is {0}."),
    (rf"\bj'ai un (chien|chat) (?:nommé |nomme |appelé )({_CAP})", "relationship", "The user has a {0} named {1}."),
    (r"\bje travaille sur ([\w'-]+)", "project", "The user is working on {0}."),
]


class FactStore:
    """Per-model editable fact memory."""

    def __init__(self, db_path: str | Path):
        self.path = Path(db_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path))
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL UNIQUE,
                source TEXT NOT NULL,
                created_at TEXT NOT NULL
            )""")
        self._db.commit()

    # ---- mutations ----

    def add(self, text: str, kind: str = "misc", source: str = "explicit") -> Optional[Fact]:
        text = " ".join(text.strip().split())
        if not text:
            return None
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        try:
            cur = self._db.execute(
                "INSERT INTO facts (kind, text, source, created_at) VALUES (?,?,?,?)",
                (kind, text, source, now))
            self._db.commit()
            return Fact(cur.lastrowid, kind, text, source, now)
        except sqlite3.IntegrityError:
            return None  # duplicate fact, silently ignored

    def delete(self, fact_id: int) -> bool:
        cur = self._db.execute("DELETE FROM facts WHERE id=?", (fact_id,))
        self._db.commit()
        return cur.rowcount > 0

    def clear(self) -> int:
        cur = self._db.execute("DELETE FROM facts")
        self._db.commit()
        return cur.rowcount

    # ---- queries ----

    def all(self) -> list[Fact]:
        rows = self._db.execute(
            "SELECT id, kind, text, source, created_at FROM facts ORDER BY id").fetchall()
        return [Fact(*r) for r in rows]

    def relevant(self, query: str, limit: int = 12) -> list[Fact]:
        """Return facts relevant to the query (simple keyword overlap), else all."""
        facts = self.all()
        if not query.strip():
            return facts[:limit]
        words = {w.lower() for w in re.findall(r"\w+", query) if len(w) > 2}
        if not words:
            return facts[:limit]
        scored = []
        for f in facts:
            fw = {w.lower() for w in re.findall(r"\w+", f.text)}
            scored.append((len(words & fw), f))
        scored.sort(key=lambda s: -s[0])
        hits = [f for score, f in scored if score > 0]
        # Always include facts even if no overlap, so the model still "knows" them
        return (hits or facts)[:limit]

    # ---- extraction ----

    _STOP = {"comment", "quel", "quelle", "quels", "quelles", "quoi", "qui", "est",
             "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "les", "des",
             "une", "un", "que", "qui", "pour", "avec", "dans", "vous", "tu", "je",
             "the", "what", "who", "where", "your", "you", "name", "and", "how"}

    def search(self, query: str, limit: int = 100) -> list[Fact]:
        """Rank the stored facts by relevance to a free-text query — keyword overlap PLUS
        multilingual semantic similarity (the local embedder), so « métier » surfaces
        « infirmière ». Best-first; an empty query returns every fact in normal order.
        Powers the Mémoire search box (live filter)."""
        facts = self.all()
        q = query.strip()
        if not q or not facts:
            return facts
        qw = {w.lower() for w in re.findall(r"\w+", q) if len(w) > 1} - self._STOP
        sims = _semantic_scores(q, [f.text for f in facts])
        scored: list[tuple[float, int, Fact]] = []
        for i, f in enumerate(facts):
            fw = {w.lower() for w in re.findall(r"\w+", f.text)}
            overlap = len(qw & fw)
            kw = overlap / len(qw) if qw else 0.0          # 0..1 keyword overlap
            sem = sims[i] if sims is not None else 0.0      # cosine, ~ -1..1
            # keep a fact if a keyword matched OR it's semantically close enough.
            # 0.12: model2vec static embeddings score true cross-term matches low
            # (métier→infirmière ≈0.15, sport→randonnée ≈0.14) while noise sits ≤0.11.
            if overlap > 0 or sem >= 0.12:
                scored.append((max(kw, sem), i, f))
        scored.sort(key=lambda s: (-s[0], s[1]))
        return [f for _, _, f in scored][:limit]

    def best_match(self, query: str) -> Optional[Fact]:
        """The fact most relevant to a question — hybrid keyword + semantic match.
        Lets the chat answer fact-questions reliably from memory (not the LLM),
        even when the wording differs ('métier' → 'boulanger')."""
        facts = self.all()
        if not facts:
            return None
        qw = {w.lower() for w in re.findall(r"\w+", query) if len(w) > 2} - self._STOP

        # 1) Exact keyword overlap (cheap, high precision)
        kw_best, kw_n = None, 0
        for f in facts:
            fw = {w.lower() for w in re.findall(r"\w+", f.text)}
            n = len(qw & fw)
            if n > kw_n:
                kw_n, kw_best = n, f
        if kw_n >= 2:
            return kw_best

        # 2) Semantic similarity (handles synonyms / paraphrase), if available
        sims = _semantic_scores(query, [f.text for f in facts])
        if sims is not None:
            i = int(max(range(len(sims)), key=lambda j: sims[j]))
            if sims[i] >= 0.26:
                return facts[i]

        return kw_best if kw_n >= 1 and len(qw) <= 2 else None

    def extract_and_store(self, message: str) -> list[Fact]:
        """Pull facts from a user message and store them. Returns the new facts."""
        added: list[Fact] = []

        # Explicit: "remember that X" / "retiens que X"
        m = re.search(r"\b(?:remember(?: that)?|retiens(?: que)?)\b[:,]?\s+(.+)", message, re.I)
        if m:
            f = self.add(m.group(1).rstrip(". "), kind="misc", source="explicit")
            if f:
                added.append(f)
            return added

        for pattern, kind, template in _PATTERNS:
            for match in re.finditer(pattern, message, re.I):
                groups = [g.strip() if g else "" for g in match.groups()]
                if any(not g for g in groups):
                    continue  # require all captures present
                text = re.sub(r"\s+", " ", template.format(*groups)).strip()
                f = self.add(text, kind=kind, source="auto")
                if f:
                    added.append(f)
        return added

    def summary(self) -> str:
        """A short preamble listing what is known about the user (for prompt injection)."""
        facts = self.all()
        if not facts:
            return ""
        lines = "\n".join(f"- {f.text}" for f in facts)
        return f"Things you know about the user:\n{lines}"


# --- Optional local semantic matching (multilingual, lightweight, no torch) ---
_EMBEDDER = None
_EMBEDDER_TRIED = False


def _get_embedder():
    global _EMBEDDER, _EMBEDDER_TRIED
    if _EMBEDDER_TRIED:
        return _EMBEDDER
    _EMBEDDER_TRIED = True
    try:
        from model2vec import StaticModel
        _EMBEDDER = StaticModel.from_pretrained("minishlab/potion-multilingual-128M")
    except Exception:
        _EMBEDDER = None
    return _EMBEDDER


def _semantic_scores(query: str, texts: list[str]):
    """Cosine similarity of `query` against each text, or None if unavailable."""
    m = _get_embedder()
    if m is None:
        return None
    try:
        import numpy as np
        vecs = m.encode([query] + texts)
        vecs = vecs / (np.linalg.norm(vecs, axis=1, keepdims=True) + 1e-9)
        q, rest = vecs[0], vecs[1:]
        return [float(q @ r) for r in rest]
    except Exception:
        return None


# --- Multilingual fact categorisation (§4.D « catégories ») -------------------
# LANGUAGE-NEUTRAL by design (§2.7): a fact is compared to a few prototype phrases
# per category with the multilingual embedder — NO regex, NO per-language rules.
# Each category lists prototypes in several languages; we take the best match.
_KIND_PROTOTYPES: dict[str, list[str]] = {
    "travail":  ["métier travail profession emploi job work occupation carrière",
                 "je suis infirmière médecin ingénieur professeur développeur",
                 "Beruf Arbeit", "trabajo profesión empleo", "工作 职业"],
    "projet":   ["projet objectif but project goal",
                 "je travaille sur je construis je crée un",
                 "Projekt Ziel", "proyecto objetivo", "项目 目标"],
    "goûts":    ["aime adore préfère passion loisir hobby like enjoy favourite taste",
                 "musique guitare sport randonnée lecture cuisine voyage jeux films",
                 "Hobby mag gern", "gusta afición pasatiempo", "爱好 喜欢"],
    "lieu":     ["habite vit ville pays région adresse lives in city country location",
                 "à Paris Toulouse Lyon en France au Canada",
                 "wohnt Stadt Land", "vive ciudad país", "住在 城市 国家"],
    "relation": ["mon ami ma famille mon mari ma femme mon enfant mon collègue",
                 "mon chien mon chat animal de compagnie pet",
                 "meine Familie mein Hund", "mi familia mi perro mi gato", "我的家人 我的宠物"],
    "perso":    ["s'appelle il s'appelle elle s'appelle", "je m'appelle mon prénom mon nom",
                 "se llama me llamo mi nombre es", "Ich heiße mein Name",
                 "chamo-me o meu nome é", "is named is called my name",
                 "名叫 名字", "âge ans santé allergie identité personnelle"],
}


def classify_kind(text: str, threshold: float = 0.18) -> str:
    """Best-matching category for a fact, or 'misc' if none is confident enough.
    Multilingual (semantic), so it works in any language (§2.7)."""
    text = (text or "").strip()
    if not text:
        return "misc"
    cats = list(_KIND_PROTOTYPES.keys())
    protos, owner = [], []
    for ci, c in enumerate(cats):
        for p in _KIND_PROTOTYPES[c]:
            protos.append(p); owner.append(ci)
    sims = _semantic_scores(text, protos)
    if sims is None:
        return "misc"
    best = [-1.0] * len(cats)
    for s, ci in zip(sims, owner):
        if s > best[ci]:
            best[ci] = s
    bi = max(range(len(cats)), key=lambda i: best[i])
    return cats[bi] if best[bi] >= threshold else "misc"


def store_for_model(model_name: str, models_dir: Optional[Path] = None) -> FactStore:
    """Open the FactStore for a personal model by name."""
    base = models_dir or (Path.home() / ".aneforge" / "models")
    return FactStore(base / model_name / "memory.db")
