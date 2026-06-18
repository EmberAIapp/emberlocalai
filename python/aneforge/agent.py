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


def _esc(s):
    """Escape a string for embedding in an AppleScript double-quoted literal."""
    return (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


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


def notes_corpus(limit: int = 40, max_chars: int = 8000):
    """Read the user's Apple Notes (title + body) as plain text, for REAL ingestion (§4.A
    connecteurs locaux · lecture seule). Returns (corpus, used, total). Bodies are HTML →
    tags stripped. Capped (count + chars) to keep ingestion snappy; honest about the cap."""
    import re as _re
    ok, _ = _launch("Notes")
    if not ok:
        return "", 0, 0
    # Iterate by index with explicit delimiters (commas in note text break list parsing).
    script = (
        'tell application "Notes"\n'
        '  set theNotes to notes\n'
        '  set total to count of theNotes\n'
        f'  set lim to {int(limit)}\n'
        '  if lim > total then set lim to total\n'
        '  set out to ""\n'
        '  repeat with i from 1 to lim\n'
        '    set t to item i of theNotes\n'
        '    set out to out & (name of t) & "@@T@@" & (body of t) & "@@N@@"\n'
        '  end repeat\n'
        '  return (total as text) & "@@C@@" & out\n'
        'end tell'
    )
    raw = _osa(script, timeout=45)
    if not raw or raw.startswith("Erreur"):
        return "", 0, 0
    total_str, _, body = raw.partition("@@C@@")
    try:
        total = int(total_str.strip())
    except Exception:
        total = 0
    parts, used = [], 0
    for chunk in body.split("@@N@@"):
        if not chunk.strip():
            continue
        title, _, html = chunk.partition("@@T@@")
        txt = _re.sub(r"<[^>]+>", " ", html)        # strip HTML tags
        txt = _re.sub(r"&[a-z]+;", " ", txt)        # crude entity strip
        txt = _re.sub(r"\s+", " ", txt).strip()
        block = (title.strip() + ". " + txt).strip(". ").strip()
        if not block:
            continue
        parts.append(block)
        used += 1
        if sum(len(p) for p in parts) >= max_chars:
            break
    return "\n\n".join(parts)[:max_chars], used, total


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
    # --- P2 ecosystem (write/create — reversible, each gated by permission) ---
    {"type": "function", "function": {"name": "write_clipboard",
     "description": "Put text into the clipboard.",
     "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}},
    {"type": "function", "function": {"name": "create_note",
     "description": "Create a note in Notes.",
     "parameters": {"type": "object", "properties": {"title": {"type": "string"},
                    "body": {"type": "string"}}, "required": ["title", "body"]}}},
    {"type": "function", "function": {"name": "create_reminder",
     "description": "Create a reminder in Reminders.",
     "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}},
    {"type": "function", "function": {"name": "create_event",
     "description": "Create a calendar event. start as 'YYYY-MM-DD HH:MM'.",
     "parameters": {"type": "object", "properties": {"title": {"type": "string"},
                    "start": {"type": "string"}, "duration_min": {"type": "integer"}},
                    "required": ["title", "start"]}}},
    {"type": "function", "function": {"name": "move_file",
     "description": "Move or rename a file.",
     "parameters": {"type": "object", "properties": {"src": {"type": "string"},
                    "dst": {"type": "string"}}, "required": ["src", "dst"]}}},
    {"type": "function", "function": {"name": "copy_file",
     "description": "Copy a file.",
     "parameters": {"type": "object", "properties": {"src": {"type": "string"},
                    "dst": {"type": "string"}}, "required": ["src", "dst"]}}},
    {"type": "function", "function": {"name": "music_control",
     "description": "Control Music: play, pause, next, previous, stop.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "draft_mail",
     "description": "Compose a DRAFT email (opens it, never sends).",
     "parameters": {"type": "object", "properties": {"to": {"type": "string"}, "subject": {"type": "string"},
                    "body": {"type": "string"}}, "required": ["subject", "body"]}}},
    {"type": "function", "function": {"name": "run_shortcut",
     "description": "Run an Apple Shortcut by name.",
     "parameters": {"type": "object", "properties": {"name": {"type": "string"},
                    "input": {"type": "string"}}, "required": ["name"]}}},
    {"type": "function", "function": {"name": "finish",
     "description": "Finish the task with a short summary for the user.",
     "parameters": {"type": "object", "properties": {"summary": {"type": "string"}}, "required": ["summary"]}}},
]
# scope = human label shown in the permission gate. `notify` is intentionally UNGATED (harmless).
# Everything that touches files/apps/personal data — or whose RESULT is exfiltrated to the cloud
# brain — asks permission.
SENSITIVE = {
    "list_dir": "Fichiers", "read_file": "Fichiers", "write_note": "Fichiers",
    "open_app": "Apps", "open_url": "Apps", "reveal_in_finder": "Fichiers",
    "spotlight_search": "Fichiers", "search_text": "Fichiers",
    "read_notes": "Notes", "read_reminders": "Rappels", "read_calendar": "Agenda",
    # Reading the user's PERSONAL MEMORY is sensitive too — its content is sent to the cloud
    # brain, so it must be gated (was previously ungated → silent exfiltration). §7.
    "list_facts": "Mémoire", "search_memory": "Mémoire",
    # read_clipboard EXFILTRATES whatever is on the clipboard (passwords, 2FA codes…) to DeepSeek →
    # Tier-3 (always ask, never auto-allowed). §7.
    "read_clipboard": "Presse-papiers-lecture",
    # P2 — write/create (reversible), each gated:
    "write_clipboard": "Presse-papiers", "create_note": "Notes", "create_reminder": "Rappels",
    "create_event": "Agenda", "move_file": "Fichiers", "copy_file": "Fichiers",
    "music_control": "Musique", "draft_mail": "Mail", "run_shortcut": "Raccourcis",
}
# Cloud egress consent — Mode Her's brain is DeepSeek (cloud): the task + every tool RESULT
# (file contents, notes, memory…) is sent there. The user must explicitly consent to that egress,
# once per task, BEFORE anything leaves. Tier-3 → never auto-allowed, never silently remembered.
CLOUD_SCOPE = "Cloud (DeepSeek)"
# Scopes that must NEVER be auto-allowed / "remembered" — always per-action confirm. run_shortcut
# can do anything (it runs a user shortcut), so it's Tier-3 too. (P3 send/delete/screen come later.)
TIER3_SCOPES = {CLOUD_SCOPE, "Raccourcis", "Mail-envoi", "Messages-envoi",
                "Agenda-invitation", "Fichiers-suppr", "Écran", "Presse-papiers-lecture"}


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

    # --- P2 ecosystem (write/create, reversible) ---
    if name == "write_clipboard":
        try:
            subprocess.run(["pbcopy"], input=args.get("text", ""), text=True, timeout=5)
        except Exception as e:
            return f"Erreur : {e}"
        return "Copié dans le presse-papiers."
    if name == "create_note":
        ok, msg = _launch("Notes")
        if not ok:
            return msg
        _osa(f'tell application "Notes" to make new note with properties '
             f'{{name:"{_esc(args.get("title","Note"))}", body:"{_esc(args.get("body",""))}"}}', 20)
        return f"Note créée : {args.get('title','Note')}"
    if name == "create_reminder":
        ok, msg = _launch("Reminders")
        if not ok:
            return msg
        _osa(f'tell application "Reminders" to make new reminder with properties '
             f'{{name:"{_esc(args.get("text","Rappel"))}"}}', 20)
        return f"Rappel créé : {args.get('text','')}"
    if name == "create_event":
        ok, msg = _launch("Calendar")
        if not ok:
            return msg
        from datetime import datetime
        try:
            dt = datetime.fromisoformat(args.get("start", "").replace("/", "-").strip())
        except Exception:
            return "Date invalide (attendu « AAAA-MM-JJ HH:MM »)."
        dur = int(args.get("duration_min") or 60)
        script = (f'set d to current date\nset year of d to {dt.year}\nset month of d to {dt.month}\n'
                  f'set day of d to {dt.day}\nset hours of d to {dt.hour}\nset minutes of d to {dt.minute}\n'
                  f'set seconds of d to 0\n'
                  f'tell application "Calendar" to tell calendar 1 to make new event with properties '
                  f'{{summary:"{_esc(args.get("title","Événement"))}", start date:d, end date:(d + {dur} * 60)}}')
        out = _osa(script, 25)
        return f"Événement créé : {args.get('title','')} le {dt:%d/%m %H:%M}" if "error" not in out.lower() else f"Échec calendrier : {out[:120]}"
    if name == "move_file":
        import shutil
        src = str(Path(args.get("src", "")).expanduser()); dst = str(Path(args.get("dst", "")).expanduser())
        try:
            shutil.move(src, dst)
        except Exception as e:
            return f"Déplacement impossible : {e}"
        return f"Déplacé : {src} → {dst}"
    if name == "copy_file":
        import shutil
        src = str(Path(args.get("src", "")).expanduser()); dst = str(Path(args.get("dst", "")).expanduser())
        try:
            shutil.copy2(src, dst)
        except Exception as e:
            return f"Copie impossible : {e}"
        return f"Copié : {src} → {dst}"
    if name == "music_control":
        ok, msg = _launch("Music", settle=0.4)
        if not ok:
            return msg
        act = {"play": "play", "pause": "pause", "next": "next track",
               "previous": "previous track", "stop": "stop"}.get(args.get("action", "play"), "play")
        _osa(f'tell application "Music" to {act}', 10)
        return f"Musique : {args.get('action','play')}"
    if name == "draft_mail":
        ok, msg = _launch("Mail")
        if not ok:
            return msg
        to = _esc(args.get("to", "")); subj = _esc(args.get("subject", "")); body = _esc(args.get("body", ""))
        script = ('tell application "Mail"\n'
                  f'set m to make new outgoing message with properties {{subject:"{subj}", content:"{body}", visible:true}}\n'
                  + (f'tell m to make new to recipient with properties {{address:"{to}"}}\n' if to else '')
                  + 'end tell')
        _osa(script, 20)
        return f"Brouillon de mail prêt{(' pour ' + args.get('to','')) if args.get('to') else ''} (NON envoyé)."
    if name == "run_shortcut":
        sc = (args.get("name") or "").strip()
        if not sc:
            return "Nom du raccourci manquant."
        cmd = ["shortcuts", "run", sc]
        inp = args.get("input")
        if inp:
            cmd += ["-i", "-"]
        try:
            r = subprocess.run(cmd, input=(inp or None), capture_output=True, text=True, timeout=40)
        except Exception as e:
            return f"Erreur : {e}"
        if r.returncode != 0:
            return f"Raccourci « {sc} » a échoué : {(r.stderr or '').strip()[:140] or 'introuvable'}"
        return f"Raccourci « {sc} » exécuté. {(r.stdout or '').strip()[:140]}"
    return "Outil inconnu."


def run_agent(ia, task, emit, ask_permission, max_steps=8, should_stop=None):
    """Drive the DeepSeek tool-use loop.
    emit(event: dict)                  -> stream a UI event.
    ask_permission(tool, args, scope)  -> bool, blocks until the user decides (sensitive tools).
    should_stop()                      -> bool ; checked before every cloud call AND every tool
                                          execution so « Stop » halts the worker server-side
                                          (no tool runs after the user cancels). §3.
    """
    def stopped():
        return bool(should_stop and should_stop())

    sys = ("Tu es l'agent d'Ember, l'IA personnelle locale de l'utilisateur. Accomplis la tâche "
           "en utilisant les outils, étape par étape, de façon concrète et brève. Réponds dans la "
           "langue de l'utilisateur. N'invente jamais un fait : sers-toi des outils. Quand c'est fini, "
           "appelle finish avec un court résumé.")
    messages = [{"role": "system", "content": sys}, {"role": "user", "content": task}]
    emit({"type": "plan", "text": task})
    if stopped():
        emit({"type": "done", "summary": "Arrêté."}); return
    # CONSENTEMENT CLOUD explicite (§7) — rien ne part avant un OUI clair. Le cerveau est DeepSeek :
    # la tâche + les résultats d'outils (fichiers, notes, mémoire lus) y seront envoyés.
    if not ask_permission("__cloud__", {"task": task}, CLOUD_SCOPE):
        emit({"type": "done", "summary": "Tâche annulée — envoi vers le cloud refusé. Rien n'est sorti."})
        return
    for _ in range(max_steps):
        if stopped():
            emit({"type": "done", "summary": "Arrêté — aucune autre action."}); return
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
            # Vérifie l'arrêt AVANT d'exécuter l'outil → aucune mutation (déplacement, brouillon mail,
            # événement…) ne se produit après « Stop ».
            if stopped():
                emit({"type": "done", "summary": "Arrêté — action non exécutée."}); return
            emit({"type": "tool", "name": name, "args": args})
            scope = SENSITIVE.get(name)
            if scope and not ask_permission(name, args, scope):
                result = "Action refusée par l'utilisateur."
                emit({"type": "observation", "name": name, "text": result, "denied": True})
            elif stopped():
                emit({"type": "done", "summary": "Arrêté — action non exécutée."}); return
            else:
                try:
                    result = _exec(name, args, ia)
                except Exception as e:
                    result = f"Erreur : {e}"
                emit({"type": "observation", "name": name, "text": str(result)[:600]})
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": str(result)[:4000]})
    emit({"type": "done", "summary": "Limite d'étapes atteinte."})
