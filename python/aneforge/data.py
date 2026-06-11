"""Data loading and tokenization pipeline."""

import json
from pathlib import Path
from typing import Optional


def load_data(
    path: str,
    format: str = "auto",
    seq_len: int = 256,
    model_name: str = "smollm2-135m",
    max_samples: Optional[int] = None,
) -> list[int]:
    """
    Load and tokenize data from various file formats.

    Supported formats:
    - txt: Plain text, split into chunks
    - jsonl: JSON Lines with 'text' or 'content' field
    - chat: JSON Lines with 'messages' array (OpenAI format)

    Returns list of token IDs.
    """
    filepath = Path(path)

    if format == "auto":
        format = _detect_format(filepath)

    if format == "txt":
        texts = _load_txt(filepath, max_samples)
    elif format == "jsonl":
        texts = _load_jsonl(filepath, max_samples)
    elif format == "chat":
        texts = _load_chat(filepath, max_samples)
    elif format == "csv":
        texts = _load_csv(filepath, max_samples)
    else:
        raise ValueError(f"Unknown format: {format}. Supported: txt, jsonl, chat, csv")

    # Tokenize
    tokens = tokenize_text("\n".join(texts), model_name)

    return tokens


def tokenize_text(text: str, model_name: str = "smollm2-135m") -> list[int]:
    """Tokenize text using the model's tokenizer."""
    try:
        from tokenizers import Tokenizer
        from aneforge.model import get_hf_model_id
        from huggingface_hub import hf_hub_download

        hf_id = get_hf_model_id(model_name)
        try:
            tok_path = hf_hub_download(hf_id, "tokenizer.json")
            tokenizer = Tokenizer.from_file(tok_path)
            encoding = tokenizer.encode(text)
            return encoding.ids
        except Exception:
            pass
    except ImportError:
        pass

    # Fallback: simple character-level tokenization
    return _simple_tokenize(text)


def _simple_tokenize(text: str) -> list[int]:
    """Simple fallback tokenizer (character-level with basic vocab)."""
    # Build a basic byte-level tokenizer
    tokens = []
    for byte in text.encode("utf-8"):
        tokens.append(int(byte))
    return tokens


def _detect_format(path: Path) -> str:
    """Auto-detect file format from extension and content."""
    suffix = path.suffix.lower()

    if suffix == ".txt":
        return "txt"
    elif suffix == ".jsonl":
        # Check if it's chat format
        try:
            with open(path) as f:
                first_line = json.loads(f.readline())
                if "messages" in first_line:
                    return "chat"
                return "jsonl"
        except (json.JSONDecodeError, KeyError):
            return "jsonl"
    elif suffix == ".json":
        return "jsonl"
    elif suffix == ".csv":
        return "csv"
    else:
        return "txt"


def _load_txt(path: Path, max_samples: Optional[int]) -> list[str]:
    """Load plain text file."""
    with open(path, encoding="utf-8") as f:
        text = f.read()

    # Split into paragraphs
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

    if max_samples:
        paragraphs = paragraphs[:max_samples]

    return paragraphs


def _load_jsonl(path: Path, max_samples: Optional[int]) -> list[str]:
    """Load JSON Lines file."""
    texts = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if max_samples and len(texts) >= max_samples:
                break
            try:
                obj = json.loads(line)
                # Try common field names
                text = obj.get("text") or obj.get("content") or obj.get("input") or ""
                if text:
                    texts.append(text)
            except json.JSONDecodeError:
                continue
    return texts


def _load_chat(path: Path, max_samples: Optional[int]) -> list[str]:
    """Load chat format (OpenAI-style messages)."""
    texts = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if max_samples and len(texts) >= max_samples:
                break
            try:
                obj = json.loads(line)
                messages = obj.get("messages", [])
                # Format as conversation
                parts = []
                for msg in messages:
                    role = msg.get("role", "user")
                    content = msg.get("content", "")
                    parts.append(f"<|{role}|>\n{content}")
                if parts:
                    texts.append("\n".join(parts))
            except json.JSONDecodeError:
                continue
    return texts


def _load_csv(path: Path, max_samples: Optional[int]) -> list[str]:
    """Load CSV file (uses first text column)."""
    import csv
    texts = []
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if max_samples and len(texts) >= max_samples:
                break
            # Try common column names
            for col in ["text", "content", "input", "sentence", "document"]:
                if col in row and row[col]:
                    texts.append(row[col])
                    break
    return texts
