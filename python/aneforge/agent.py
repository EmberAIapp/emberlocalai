"""Ember agent — a real task-executing agent (Mode Her / §4.E, §9.D).

The local 1.5B chat model is too small for reliable multi-step tool use, so the AGENT brain
is DeepSeek (OpenAI-compatible API). HONESTY (§2.4): this part is NOT 100% local — it calls
api.deepseek.com. Chat + memory stay local. Tools are local & safe; sensitive ones (files,
apps) require explicit user permission, granular & revocable (§4.E / §7).

API key is read at runtime from env DEEPSEEK_API_KEY or ~/.aneforge/deepseek.key — never
hard-coded, never committed.
"""

from __future__ import annotations

import json
import os
import urllib.request
from pathlib import Path

from aneforge.memory import store_for_model

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DRAFTS = Path.home() / ".aneforge" / "drafts"


def _read(p: Path):
    try:
        return p.read_text().strip()
    except Exception:
        return None


def api_key():
    return (os.environ.get("DEEPSEEK_API_KEY")
            or _read(Path.home() / ".aneforge" / "deepseek.key")
            or _read(Path.home() / ".ember-engine" / "deepseek.key"))


def available() -> bool:
    return bool(api_key())


def _deepseek(messages, tools):
    key = api_key()
    if not key:
        raise RuntimeError("Clé DeepSeek absente (~/.aneforge/deepseek.key).")
    body = {"model": "deepseek-chat", "messages": messages, "tools": tools,
            "tool_choice": "auto", "temperature": 0.2, "max_tokens": 700}
    req = urllib.request.Request(
        DEEPSEEK_URL, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)["choices"][0]["message"]


# --- Tools (all local; SENSITIVE ones gate on permission) ---
TOOLS = [
    {"type": "function", "function": {"name": "list_facts",
     "description": "List everything Ember knows about the user (local memory).",
     "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "search_memory",
     "description": "Search the user's local memory for a fact.",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "list_dir",
     "description": "List entries in a folder on the user's Mac.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "read_file",
     "description": "Read a UTF-8 text file on the user's Mac (first 4000 chars).",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "write_note",
     "description": "Write a note/draft into the user's Ember drafts folder.",
     "parameters": {"type": "object", "properties": {"filename": {"type": "string"},
                    "content": {"type": "string"}}, "required": ["filename", "content"]}}},
    {"type": "function", "function": {"name": "finish",
     "description": "Finish the task with a short summary for the user.",
     "parameters": {"type": "object", "properties": {"summary": {"type": "string"}}, "required": ["summary"]}}},
]
SENSITIVE = {"list_dir": "Fichiers", "read_file": "Fichiers", "write_note": "Fichiers"}


def _exec(name, args, ia):
    if name == "list_facts":
        facts = store_for_model(ia).all()
        return "\n".join(f"- {f.text}" for f in facts) or "Mémoire vide."
    if name == "search_memory":
        f = store_for_model(ia).best_match(args.get("query", ""))
        return f.text if f else "Aucun fait correspondant."
    if name == "list_dir":
        p = Path(args.get("path", "")).expanduser()
        if not p.is_dir():
            return f"Pas un dossier : {p}"
        return "\n".join(sorted(x.name for x in list(p.iterdir())[:60]))
    if name == "read_file":
        p = Path(args.get("path", "")).expanduser()
        try:
            return p.read_text(errors="replace")[:4000]
        except Exception as e:
            return f"Lecture impossible : {e}"
    if name == "write_note":
        DRAFTS.mkdir(parents=True, exist_ok=True)
        fn = args.get("filename", "note")
        if not fn.endswith((".md", ".txt")):
            fn += ".md"
        path = DRAFTS / fn
        path.write_text(args.get("content", ""))
        return f"Note écrite : {path}"
    return "Outil inconnu."


def run_agent(ia, task, emit, ask_permission, max_steps=8):
    """Drive the DeepSeek tool-use loop.
    emit(event: dict)               -> stream a UI event.
    ask_permission(tool, args, scope) -> bool, blocks until the user decides (sensitive tools).
    """
    sys = ("Tu es l'agent d'Ember, l'IA personnelle locale de l'utilisateur. Accomplis la tâche "
           "en utilisant les outils, étape par étape, de façon concrète et brève. Réponds dans la "
           "langue de l'utilisateur. N'invente jamais un fait : sers-toi des outils. Quand c'est fini, "
           "appelle finish avec un court résumé.")
    messages = [{"role": "system", "content": sys}, {"role": "user", "content": task}]
    emit({"type": "plan", "text": task})
    for _ in range(max_steps):
        try:
            msg = _deepseek(messages, TOOLS)
        except Exception as e:
            emit({"type": "error", "text": f"Agent indisponible : {e}"})
            return
        calls = msg.get("tool_calls") or []
        if not calls:
            text = (msg.get("content") or "").strip()
            emit({"type": "done", "summary": text or "Terminé."})
            return
        messages.append(msg)
        for c in calls:
            name = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except Exception:
                args = {}
            if name == "finish":
                emit({"type": "done", "summary": args.get("summary", "Terminé.")})
                return
            emit({"type": "tool", "name": name, "args": args})
            scope = SENSITIVE.get(name)
            if scope and not ask_permission(name, args, scope):
                result = "Action refusée par l'utilisateur."
                emit({"type": "observation", "name": name, "text": result, "denied": True})
            else:
                try:
                    result = _exec(name, args, ia)
                except Exception as e:
                    result = f"Erreur : {e}"
                emit({"type": "observation", "name": name, "text": str(result)[:600]})
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": str(result)[:4000]})
    emit({"type": "done", "summary": "Limite d'étapes atteinte."})
