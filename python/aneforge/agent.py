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
import re
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime
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
    out = _run(["osascript", "-e", script], timeout)
    low = out.lower()
    # macOS Automation (TCC) not yet granted → osascript returns -1743 / "not authorized" / FR
    # "n'est pas autorisé". Turn the cryptic OS error into a clear hint the model relays to the user.
    if "-1743" in out or "not authorized to send apple events" in low or "n'est pas autoris" in low:
        return ("PERMISSION_NEEDED — macOS has not yet granted Ember permission to control this app. "
                "Tell the user, in their language, to click \"Allow\" on the macOS prompt, or to enable it "
                "in System Settings → Privacy & Security → Automation → Ember, then try again.")
    return out


def _esc(s):
    """Escape a string for embedding in an AppleScript double-quoted literal."""
    return (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


# macOS apps carry ENGLISH bundle names; `open -a` matches the bundle/file name, NOT the user's
# localized display name — so FR "Calculatrice" fails because the bundle is "Calculator". We map the
# common localized names (FR first — the launch market) and fall back to Spotlight for anything else.
_APP_ALIASES = {
    "calculatrice": "Calculator", "calendrier": "Calendar", "rappels": "Reminders",
    "réglages": "System Settings", "reglages": "System Settings",
    "réglages système": "System Settings", "reglages systeme": "System Settings",
    "préférences système": "System Settings", "preferences systeme": "System Settings",
    "courrier": "Mail", "plans": "Maps", "cartes": "Maps", "musique": "Music",
    "livres": "Books", "bourse": "Stocks", "maison": "Home", "aperçu": "Preview", "apercu": "Preview",
    "dictaphone": "Voice Memos", "notes vocales": "Voice Memos", "horloge": "Clock",
    "raccourcis": "Shortcuts", "météo": "Weather", "meteo": "Weather",
    "trousseau d'accès": "Keychain Access", "moniteur d'activité": "Activity Monitor",
    "utilitaire de disque": "Disk Utility", "navigateur": "Safari",
}


def _resolve_app(name: str) -> str:
    """Canonicalise an app name: strip leading articles, map a localized name → its bundle name."""
    n = (name or "").strip().strip('"“”\'').strip()
    n = re.sub(r"^(?:l['’]\s*application|l['’]\s*app|the\s+app|application|app|l['’])\s+",
               "", n, flags=re.I).strip()
    return _APP_ALIASES.get(n.lower(), n)


def _spotlight_app(name: str):
    """Resolve a (possibly localized) display name → an .app path via Spotlight — works for ANY app
    in ANY language (the OS indexes the localized display name)."""
    n = (name or "").strip().strip('"“”\'').replace("'", "")
    if not n:
        return None
    q = f"kMDItemContentTypeTree == 'com.apple.application-bundle' && kMDItemDisplayName == '{n}'cd"
    try:
        r = subprocess.run(["mdfind", q], capture_output=True, text=True, timeout=8)
        for line in (r.stdout or "").splitlines():
            line = line.strip()
            if line.endswith(".app"):
                return line
    except Exception:
        pass
    return None


def _launch(app, settle=1.4):
    """Launch/focus an app and wait briefly. macOS apps have ENGLISH bundle names, so we resolve
    common localized names (e.g. FR « Calculatrice » → "Calculator") and add a Spotlight fallback,
    then `open -a`. osascript→app fails -600 if not running, so read/control tools call this first."""
    resolved = _resolve_app(app)
    tried = []
    for cand in (resolved, app):
        cand = (cand or "").strip()
        if not cand or cand in tried:
            continue
        tried.append(cand)
        try:
            r = subprocess.run(["open", "-a", cand], capture_output=True, text=True, timeout=12)
        except Exception as e:
            return False, f"Erreur : {e}"
        if r.returncode == 0:
            time.sleep(settle)
            return True, f"App ouverte : {cand}"
    # Last resort: Spotlight by localized display name → open the resolved bundle path directly.
    path = _spotlight_app(app) or _spotlight_app(resolved)
    if path:
        try:
            r = subprocess.run(["open", path], capture_output=True, text=True, timeout=12)
            if r.returncode == 0:
                time.sleep(settle)
                return True, f"App ouverte : {Path(path).stem}"
        except Exception:
            pass
    return False, f"Impossible d'ouvrir « {app} » : application introuvable"


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
     "description": "Open / focus ANY installed macOS app by its name (first-party OR third-party — "
                    "Safari, Mail, Notes, Music, Calculator, Spotify, WhatsApp, VS Code, etc.). Use "
                    "the name the user gave; localized names are resolved automatically.",
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
        return f"Note written: {path}"

    # --- P1 ecosystem tools (all execute LOCALLY via subprocess/osascript) ---
    if name == "open_app":
        app = (args.get("name") or "").strip()
        if not app:
            return "Missing app name."
        ok, msg = _launch(app, settle=0.2)
        return msg
    if name == "open_url":
        url = (args.get("url") or "").strip()
        scheme = urllib.parse.urlparse(url).scheme.lower()
        if scheme not in ("http", "https", "mailto"):
            return f"Link refused (scheme “{scheme or '∅'}”; http/https/mailto only)."
        try:
            r = subprocess.run(["open", url], capture_output=True, text=True, timeout=10)
        except Exception as e:
            return f"Erreur : {e}"
        return f"Opened: {url}" if r.returncode == 0 else f"Couldn’t open link: {(r.stderr or '').strip()[:140]}"
    if name == "reveal_in_finder":
        p = str(Path(args.get("path", "")).expanduser())
        try:
            r = subprocess.run(["open", "-R", p], capture_output=True, text=True, timeout=10)
        except Exception as e:
            return f"Erreur : {e}"
        return f"Revealed in Finder: {p}" if r.returncode == 0 else f"Not found: {p}"
    if name == "spotlight_search":
        q = (args.get("query") or "").strip()
        if not q:
            return "Empty query."
        out = _run(["mdfind", "-name", q] if args.get("by_name") else ["mdfind", q], 15)
        lines = [l for l in out.splitlines() if l and "mdfind[" not in l and "UserQueryParser" not in l][:40]
        return "\n".join(lines) if lines else "No results."
    if name == "search_text":
        pat = args.get("pattern", "")
        p = str(Path(args.get("path", "")).expanduser())
        out = _run(["grep", "-rIn", "--", pat, p], 20)
        lines = out.splitlines()[:50]
        return "\n".join(lines) if lines and "Erreur" not in out else (out or "No matches.")
    if name == "read_clipboard":
        return _run(["pbpaste"], 5)
    if name == "notify":
        t = (args.get("title") or "Ember").replace('"', "'")
        b = (args.get("body") or "").replace('"', "'")
        _osa(f'display notification "{b}" with title "{t}"', 8)
        return "Notification shown."
    if name == "read_notes":
        ok, msg = _launch("Notes")
        if not ok:
            return msg
        out = _osa('tell application "Notes" to get name of notes', 25)
        items = [x.strip() for x in out.split(",") if x.strip()][:30]
        return "Notes: " + " · ".join(items) if items else "No notes."
    if name == "read_reminders":
        ok, msg = _launch("Reminders")
        if not ok:
            return msg
        out = _osa('tell application "Reminders" to get name of (reminders whose completed is false)', 25)
        items = [x.strip() for x in out.split(",") if x.strip()][:40]
        return "Reminders: " + " · ".join(items) if items else "No open reminders."
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
        return "Today: " + " · ".join(items) if items else "Nothing on the calendar today."

    # --- P2 ecosystem (write/create, reversible) ---
    if name == "write_clipboard":
        try:
            subprocess.run(["pbcopy"], input=args.get("text", ""), text=True, timeout=5)
        except Exception as e:
            return f"Erreur : {e}"
        return "Copied to the clipboard."
    if name == "create_note":
        ok, msg = _launch("Notes")
        if not ok:
            return msg
        _osa(f'tell application "Notes" to make new note with properties '
             f'{{name:"{_esc(args.get("title","Note"))}", body:"{_esc(args.get("body",""))}"}}', 20)
        return f"Note created: {args.get('title','Note')}"
    if name == "create_reminder":
        ok, msg = _launch("Reminders")
        if not ok:
            return msg
        _osa(f'tell application "Reminders" to make new reminder with properties '
             f'{{name:"{_esc(args.get("text","Rappel"))}"}}', 20)
        return f"Reminder created: {args.get('text','')}"
    if name == "create_event":
        ok, msg = _launch("Calendar")
        if not ok:
            return msg
        from datetime import datetime
        try:
            dt = datetime.fromisoformat(args.get("start", "").replace("/", "-").strip())
        except Exception:
            return "Invalid date (expected “YYYY-MM-DD HH:MM”)."
        dur = int(args.get("duration_min") or 60)
        script = (f'set d to current date\nset year of d to {dt.year}\nset month of d to {dt.month}\n'
                  f'set day of d to {dt.day}\nset hours of d to {dt.hour}\nset minutes of d to {dt.minute}\n'
                  f'set seconds of d to 0\n'
                  f'tell application "Calendar" to tell calendar 1 to make new event with properties '
                  f'{{summary:"{_esc(args.get("title","Événement"))}", start date:d, end date:(d + {dur} * 60)}}')
        out = _osa(script, 25)
        return f"Event created: {args.get('title','')} on {dt:%m/%d %H:%M}" if "error" not in out.lower() else f"Calendar failed: {out[:120]}"
    if name == "move_file":
        import shutil
        src = str(Path(args.get("src", "")).expanduser()); dst = str(Path(args.get("dst", "")).expanduser())
        try:
            shutil.move(src, dst)
        except Exception as e:
            return f"Couldn’t move: {e}"
        return f"Moved: {src} → {dst}"
    if name == "copy_file":
        import shutil
        src = str(Path(args.get("src", "")).expanduser()); dst = str(Path(args.get("dst", "")).expanduser())
        try:
            shutil.copy2(src, dst)
        except Exception as e:
            return f"Couldn’t copy: {e}"
        return f"Copied: {src} → {dst}"
    if name == "music_control":
        ok, msg = _launch("Music", settle=0.4)
        if not ok:
            return msg
        act = {"play": "play", "pause": "pause", "next": "next track",
               "previous": "previous track", "stop": "stop"}.get(args.get("action", "play"), "play")
        _osa(f'tell application "Music" to {act}', 10)
        return f"Music: {args.get('action','play')}"
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
        return f"Email draft ready{(' for ' + args.get('to','')) if args.get('to') else ''} (NOT sent)."
    if name == "run_shortcut":
        sc = (args.get("name") or "").strip()
        if not sc:
            return "Missing shortcut name."
        cmd = ["shortcuts", "run", sc]
        inp = args.get("input")
        if inp:
            cmd += ["-i", "-"]
        try:
            r = subprocess.run(cmd, input=(inp or None), capture_output=True, text=True, timeout=40)
        except Exception as e:
            return f"Erreur : {e}"
        if r.returncode != 0:
            return f"Shortcut “{sc}” failed: {(r.stderr or '').strip()[:140] or 'not found'}"
        return f"Shortcut “{sc}” ran. {(r.stdout or '').strip()[:140]}"
    return "Unknown tool."


# Short status strings the Python loop emits directly (the model never writes these), localized so a
# FR user doesn't suddenly get English. The model's own finish summary already follows the user's
# language thanks to the system prompt below.
_LANG_STR = {
    "stopped":        {"fr": "Arrêté.", "en": "Stopped."},
    "cloud_refused":  {"fr": "Tâche annulée — envoi au cloud refusé. Rien n'a quitté ton Mac.",
                       "en": "Task canceled — cloud upload refused. Nothing left your Mac."},
    "no_action":      {"fr": "Arrêté — aucune action.", "en": "Stopped — no further action."},
    "done":           {"fr": "Terminé.", "en": "Done."},
    "action_not_run": {"fr": "Arrêté — action non exécutée.", "en": "Stopped — action not run."},
    "refused":        {"fr": "Action refusée.", "en": "Action refused by the user."},
    "step_limit":     {"fr": "Limite d'étapes atteinte.", "en": "Step limit reached."},
    "unavailable":    {"fr": "Agent indisponible : {e}", "en": "Agent unavailable: {e}"},
}
_FR_HINT = re.compile(
    r"[àâçéèêëîïôûùœ]|\b(le|la|les|un|une|des|du|je|tu|il|elle|nous|vous|mon|ma|mes|ton|ta|tes|"
    r"et|ou|pour|avec|dans|sur|ouvre|ouvrir|écris|crée|créer|rappelle|mets|fais|montre|cherche|"
    r"trouve|peux|pourrais|stp|merci|bonjour|salut|quoi|pourquoi|comment)\b", re.I)


def _detect_lang(text: str) -> str:
    """Tiny FR/EN detector for the Python-emitted status strings (the model handles every language
    itself for its own output)."""
    return "fr" if _FR_HINT.search(text or "") else "en"


def _say(key: str, lang: str) -> str:
    d = _LANG_STR.get(key, {})
    return d.get(lang) or d.get("en") or key


def run_agent(ia, task, emit, ask_permission, max_steps=12, should_stop=None, lang=None):
    """Drive the DeepSeek tool-use loop.
    emit(event: dict)                  -> stream a UI event.
    ask_permission(tool, args, scope)  -> bool, blocks until the user decides (sensitive tools).
    should_stop()                      -> bool ; checked before every cloud call AND every tool
                                          execution so « Stop » halts the worker server-side
                                          (no tool runs after the user cancels). §3.
    lang                               -> optional 'fr'/'en'… hint for status strings; auto-detected
                                          from the task when not given.
    """
    def stopped():
        return bool(should_stop and should_stop())
    lang = lang or _detect_lang(task)

    sys = ("Tu es l'agent d'Ember, l'IA personnelle locale de l'utilisateur. Accomplis la tâche en "
           "utilisant les outils, étape par étape, de façon concrète. AGIS vraiment : pour toute "
           "demande d'action (ouvrir une app, créer une note / un rappel / un événement, jouer de la "
           "musique, gérer des fichiers, chercher…), APPELLE l'outil correspondant — ne te contente "
           "jamais d'en parler ou de promettre de le faire. "
           "LANGUE : détecte la langue du message de l'utilisateur ci-dessous et réponds EXCLUSIVEMENT "
           "dans cette même langue — tes étapes ET le résumé final. Les résultats d'outils peuvent "
           "être en anglais : ignore leur langue, garde toujours celle de l'utilisateur. "
           "N'invente jamais un fait : sers-toi des outils. Quand c'est fini, appelle finish avec un "
           "court résumé DANS LA LANGUE DE L'UTILISATEUR.")
    # The model has no clock — give it the current date/time so "today/tomorrow/tonight/next week"
    # resolve correctly (esp. for create_event / create_reminder).
    now = datetime.now()
    sys += (f"\nDate et heure actuelles : {now:%Y-%m-%d %H:%M} ({now:%A}). "
            "Utilise-les pour résoudre « aujourd'hui », « demain », « ce soir », « la semaine prochaine », "
            "etc. Pour create_event, le format attendu est « YYYY-MM-DD HH:MM ».")
    messages = [{"role": "system", "content": sys}, {"role": "user", "content": task}]
    emit({"type": "plan", "text": task})
    if stopped():
        emit({"type": "done", "summary": _say("stopped", lang)}); return
    # CONSENTEMENT CLOUD explicite (§7) — rien ne part avant un OUI clair. Le cerveau est DeepSeek :
    # la tâche + les résultats d'outils (fichiers, notes, mémoire lus) y seront envoyés.
    if not ask_permission("__cloud__", {"task": task}, CLOUD_SCOPE):
        emit({"type": "done", "summary": _say("cloud_refused", lang)})
        return
    for _ in range(max_steps):
        if stopped():
            emit({"type": "done", "summary": _say("no_action", lang)}); return
        try:
            msg = _deepseek(messages, TOOLS)
        except Exception as e:
            emit({"type": "error", "text": _say("unavailable", lang).format(e=e)})
            return
        calls = msg.get("tool_calls") or []
        if not calls:
            text = (msg.get("content") or "").strip()
            emit({"type": "done", "summary": text or _say("done", lang)})
            return
        messages.append(msg)
        for c in calls:
            name = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except Exception:
                args = {}
            if name == "finish":
                emit({"type": "done", "summary": args.get("summary") or _say("done", lang)})
                return
            # Vérifie l'arrêt AVANT d'exécuter l'outil → aucune mutation (déplacement, brouillon mail,
            # événement…) ne se produit après « Stop ».
            if stopped():
                emit({"type": "done", "summary": _say("action_not_run", lang)}); return
            emit({"type": "tool", "name": name, "args": args})
            scope = SENSITIVE.get(name)
            if scope and not ask_permission(name, args, scope):
                result = _say("refused", lang)
                emit({"type": "observation", "name": name, "text": result, "denied": True})
            elif stopped():
                emit({"type": "done", "summary": _say("action_not_run", lang)}); return
            else:
                try:
                    result = _exec(name, args, ia)
                except Exception as e:
                    result = f"Erreur : {e}"
                emit({"type": "observation", "name": name, "text": str(result)[:600]})
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": str(result)[:4000]})
    emit({"type": "done", "summary": _say("step_limit", lang)})
