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
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

from aneforge.memory import store_for_model

DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
DRAFTS = Path.home() / ".aneforge" / "drafts"


def _run(cmd, timeout=15):
    """Run a local command, return its trimmed output (or a short error). Local only."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "").strip() or (r.stderr or "").strip() or "(ok)"
    except Exception as e:
        return f"Erreur : {e}"


def _osa(script, timeout=20):
    return _run(["osascript", "-e", script], timeout)


def _launch(app, settle=1.4):
    """Launch/focus an app and wait briefly. osascript→app fails with -600 if the app isn't
    running, so read/control tools call this first. Returns (ok, message)."""
    try:
        r = subprocess.run(["open", "-a", app], capture_output=True, text=True, timeout=12)
    except Exception as e:
        return False, f"Erreur : {e}"
    if r.returncode != 0:
        return False, f"Impossible d'ouvrir « {app} » : {(r.stderr or '').strip()[:140] or 'app introuvable'}"
    time.sleep(settle)
    return True, f"App ouverte : {app}"


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
    # --- P1 ecosystem (apps + computer): safe reads & launch, all LOCAL execution, gated ---
    {"type": "function", "function": {"name": "open_app",
     "description": "Open / focus a macOS app by name (e.g. Safari, Mail, Notes, Music).",
     "parameters": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}},
    {"type": "function", "function": {"name": "open_url",
     "description": "Open a web/mail link (http, https or mailto only).",
     "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}}},
    {"type": "function", "function": {"name": "reveal_in_finder",
     "description": "Reveal a file or folder in the Finder.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "spotlight_search",
     "description": "Find files on the Mac by name or content (Spotlight).",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"},
                    "by_name": {"type": "boolean"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "search_text",
     "description": "Search for a text pattern inside files of a folder.",
     "parameters": {"type": "object", "properties": {"pattern": {"type": "string"},
                    "path": {"type": "string"}}, "required": ["pattern", "path"]}}},
    {"type": "function", "function": {"name": "read_clipboard",
     "description": "Read the current clipboard text.",
     "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "notify",
     "description": "Show a macOS notification to the user.",
     "parameters": {"type": "object", "properties": {"title": {"type": "string"},
                    "body": {"type": "string"}}, "required": ["body"]}}},
    {"type": "function", "function": {"name": "read_notes",
     "description": "List the user's Notes (titles).",
     "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "read_reminders",
     "description": "List the user's open reminders.",
     "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "read_calendar",
     "description": "List today's calendar events.",
     "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "finish",
     "description": "Finish the task with a short summary for the user.",
     "parameters": {"type": "object", "properties": {"summary": {"type": "string"}}, "required": ["summary"]}}},
]
# scope = human label shown in the permission gate. read_clipboard/notify are intentionally
# UNGATED (harmless). Everything that touches files/apps/personal data asks permission.
SENSITIVE = {
    "list_dir": "Fichiers", "read_file": "Fichiers", "write_note": "Fichiers",
    "open_app": "Apps", "open_url": "Apps", "reveal_in_finder": "Fichiers",
    "spotlight_search": "Fichiers", "search_text": "Fichiers",
    "read_notes": "Notes", "read_reminders": "Rappels", "read_calendar": "Agenda",
}
# Scopes that must NEVER be auto-allowed / "remembered" — always per-action confirm (future P3:
# sending mail/messages, calendar invites, trashing files, on-screen control).
TIER3_SCOPES = {"Mail-envoi", "Messages-envoi", "Agenda-invitation", "Fichiers-suppr", "Écran"}


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

    # --- P1 ecosystem tools (all execute LOCALLY via subprocess/osascript) ---
    if name == "open_app":
        app = (args.get("name") or "").strip()
        if not app:
            return "Nom d'app manquant."
        ok, msg = _launch(app, settle=0.2)
        return msg
    if name == "open_url":
        url = (args.get("url") or "").strip()
        scheme = urllib.parse.urlparse(url).scheme.lower()
        if scheme not in ("http", "https", "mailto"):
            return f"Lien refusé (schéma « {scheme or '∅'} » ; http/https/mailto uniquement)."
        try:
            r = subprocess.run(["open", url], capture_output=True, text=True, timeout=10)
        except Exception as e:
            return f"Erreur : {e}"
        return f"Ouvert : {url}" if r.returncode == 0 else f"Lien impossible : {(r.stderr or '').strip()[:140]}"
    if name == "reveal_in_finder":
        p = str(Path(args.get("path", "")).expanduser())
        try:
            r = subprocess.run(["open", "-R", p], capture_output=True, text=True, timeout=10)
        except Exception as e:
            return f"Erreur : {e}"
        return f"Révélé dans le Finder : {p}" if r.returncode == 0 else f"Introuvable : {p}"
    if name == "spotlight_search":
        q = (args.get("query") or "").strip()
        if not q:
            return "Requête vide."
        out = _run(["mdfind", "-name", q] if args.get("by_name") else ["mdfind", q], 15)
        lines = [l for l in out.splitlines() if l and "mdfind[" not in l and "UserQueryParser" not in l][:40]
        return "\n".join(lines) if lines else "Aucun résultat."
    if name == "search_text":
        pat = args.get("pattern", "")
        p = str(Path(args.get("path", "")).expanduser())
        out = _run(["grep", "-rIn", "--", pat, p], 20)
        lines = out.splitlines()[:50]
        return "\n".join(lines) if lines and "Erreur" not in out else (out or "Aucune correspondance.")
    if name == "read_clipboard":
        return _run(["pbpaste"], 5)
    if name == "notify":
        t = (args.get("title") or "Ember").replace('"', "'")
        b = (args.get("body") or "").replace('"', "'")
        _osa(f'display notification "{b}" with title "{t}"', 8)
        return "Notification affichée."
    if name == "read_notes":
        ok, msg = _launch("Notes")
        if not ok:
            return msg
        out = _osa('tell application "Notes" to get name of notes', 25)
        items = [x.strip() for x in out.split(",") if x.strip()][:30]
        return "Notes : " + " · ".join(items) if items else "Aucune note."
    if name == "read_reminders":
        ok, msg = _launch("Reminders")
        if not ok:
            return msg
        out = _osa('tell application "Reminders" to get name of (reminders whose completed is false)', 25)
        items = [x.strip() for x in out.split(",") if x.strip()][:40]
        return "Rappels : " + " · ".join(items) if items else "Aucun rappel ouvert."
    if name == "read_calendar":
        ok, msg = _launch("Calendar")
        if not ok:
            return msg
        script = ('set today to current date\nset startOfDay to today - (time of today)\n'
                  'set endOfDay to startOfDay + 86400\n'
                  'tell application "Calendar" to set ev to summary of '
                  '(every event of every calendar whose start date ≥ startOfDay and start date < endOfDay)\n'
                  'return ev')
        out = _osa(script, 30)
        items = [x.strip() for x in out.split(",") if x.strip()][:30]
        return "Aujourd'hui : " + " · ".join(items) if items else "Rien au calendrier aujourd'hui."
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
