"""Ember daemon — a persistent local HTTP server that holds the MLX model + memory
in RAM so chat is instant (no per-message reload). The Swift app talks to this over
localhost instead of spawning a CLI per message.

Run:  python -m aneforge.ember_daemon [--port 8765] [--model <mlx-id>]
Endpoints (all localhost, JSON):
  GET  /health                      -> {ok, model, ready}
  GET  /models                      -> [{name, base, version, ...}]
  POST /create   {name, base}       -> {ok}
  POST /delete   {name}             -> {ok}
  POST /chat     {name, prompt}     -> {answer, learned:[...], source}
  GET  /memory?name=NAME            -> [{id, kind, text, source}]
  POST /forget   {name, id|all}     -> {ok, removed}
  POST /reset    {name}             -> {ok}   (clear conversation history)

100% local. Binds to 127.0.0.1 only.
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from aneforge.personal import PersonalModel, MODELS_DIR
from aneforge.memory import store_for_model
from aneforge import tts

_QWORDS = ("comment", "quel", "quelle", "qui", "où", "ou ", "quand", "what",
           "who", "where", "when", "how", "is ", "est-ce", "pourquoi")


def _settings_path(name: str):
    return MODELS_DIR / name / "settings.json"


def _load_settings(name: str) -> dict:
    p = _settings_path(name)
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            pass
    return {"persona": "", "max_tokens": 220}


def _save_settings(name: str, persona: str, max_tokens: int):
    _settings_path(name).write_text(json.dumps({"persona": persona, "max_tokens": max_tokens}))


def _parse_fact_array(raw: str) -> list:
    """Pull a JSON array of short fact strings out of the model's reply — robust to a missing
    closing bracket or trailing text (a small model often emits an unclosed `[ "…"`)."""
    if not raw:
        return []
    s = raw.strip()
    a = s.find("[")
    if a < 0:
        return []
    b = s.rfind("]")
    frag = s[a:b + 1] if b > a else s[a:]
    arr = None
    try:
        arr = json.loads(frag)
    except Exception:
        repaired = frag.rstrip().rstrip(",")
        if not repaired.endswith("]"):
            repaired += "]"
        try:
            arr = json.loads(repaired)
        except Exception:
            arr = re.findall(r'"((?:[^"\\]|\\.)*)"', frag)   # last resort: quoted strings
    out = []
    for x in (arr if isinstance(arr, list) else []):
        t = " ".join(str(x).split())
        if 3 <= len(t) <= 200:
            out.append(t)
    return out[:6]


def _chunk_text(text: str, max_chars: int = 220, max_chunks: int = 24) -> list:
    """Split ingested text into SENTENCE-level chunks — a small local model extracts far more
    reliably from one sentence at a time than from a dense paragraph."""
    chunks = []
    for unit in re.split(r"(?<=[.!?])\s+|\n+", text or ""):
        u = unit.strip()
        if not u:
            continue
        while len(u) > max_chars:
            chunks.append(u[:max_chars]); u = u[max_chars:]
        if u:
            chunks.append(u)
        if len(chunks) >= max_chunks:
            break
    return chunks[:max_chunks]


def _grounded(fact: str, source: str) -> bool:
    """True if the fact is supported by the source — rejects the small model's hallucinations.
    Strong rule: any PROPER NOUN (capitalised word, not sentence-initial) in the fact MUST appear
    in the source — this kills invented names/places (e.g. the prompt-example name leaking, or
    'J'habite à Paris' from a Lyon message). Plus a content-word overlap floor."""
    sl = source.lower()
    words = fact.split()
    for w in words[1:]:                       # skip the sentence-initial capital
        if re.match(r"[A-ZÀ-Ÿ][\wÀ-ÿà-ÿ'’\-]{2,}$", w):
            if w.lower().strip(".,;:!?»«\"'") not in sl:
                return False                  # invented name/place → reject
    fw = [w for w in re.findall(r"[^\W\d_]+", fact.lower(), re.UNICODE) if len(w) > 3]
    if not fw:
        return False
    hits = sum(1 for w in fw if w in sl)
    return hits / len(fw) >= 0.5


def _is_near_dup(text: str, existing: list, thresh: float = 0.80) -> bool:
    """True if `text` is essentially a restatement of a fact already stored — keeps memory
    clean (the small model paraphrases the same fact many ways: 'Thomas'/'Thomas.',
    'habite à Bordeaux'/'vis à Bordeaux'). Measured empirically: real paraphrases score
    ≥0.83 cosine, genuinely distinct facts ≤0.50 — so 0.80 collapses dups with wide margin."""
    if not existing:
        return False
    from aneforge.memory import _semantic_scores
    sims = _semantic_scores(text, existing)
    if sims is not None:
        return max(sims) >= thresh
    # fallback (embedder unavailable): high token overlap
    tw = set(re.findall(r"[^\W\d_]+", text.lower()))
    for e in existing:
        ew = set(re.findall(r"[^\W\d_]+", e.lower()))
        if tw and len(tw & ew) / len(tw | ew) >= 0.7:
            return True
    return False


# Messages that are COMMANDS / requests / questions to Ember — never durable facts about the
# user. (Clicking a suggestion like "Aide-moi à organiser ma journée" must NOT become a fact.)
_CMD_STARTS = (
    "aide", "ouvre", "lance", "liste", "résume", "resume", "montre", "présente", "presente",
    "crée", "cree", "écris", "ecris", "rédige", "redige", "cherche", "trouve", "prépare", "prepare",
    "dis", "raconte", "explique", "fais", "donne", "mets", "met ", "joue", "envoie", "traduis",
    "calcule", "génère", "genere", "peux-tu", "peux tu", "pourrais-tu", "pourrais tu", "tu peux",
    "help", "open", "list", "summar", "show", "write", "draft", "search", "find", "prepare",
    "tell", "explain", "make", "give", "play", "send", "translate", "generate", "can you",
    "could you", "please", "bonjour", "salut", "hello", "merci", "thanks",
    "rappelle", "rappelles", "remind", "quel est", "quelle est", "qui suis", "que sais",
    "qu'est-ce", "what", "who", "where", "comment je", "où est", "ou est",
)


def _looks_like_command(message: str) -> bool:
    m = (message or "").strip().lower().lstrip("«»\"'.,-–—  ").strip()
    return m.startswith(_CMD_STARTS)


def _is_real_fact(text: str) -> bool:
    """Drop extractions that aren't durable facts ABOUT THE USER: second-person lines (addressed
    to the user / command echoes), assistant boiler-plate, and PROMPT-TEMPLATE artifacts (the
    small model sometimes copies the format example literally instead of filling it in)."""
    t = text.strip().lower()
    # template/placeholder leak — angle brackets or example wording the model echoed verbatim
    if "<" in text or ">" in text:
        return False
    placeholders = ["nom écrit", "nom ecrit", "ville écrite", "ville ecrite", "le nom", "la ville",
                    "<le nom", "<la ville", "exemple", "example", "prénom écrit", "actual"]
    if any(p in t for p in placeholders):
        return False
    if t.startswith(("tu ", "vous ", "tu,", "vous,", "tu’", "t'")):
        return False
    fluff = ["besoin d'aide", "disponible pour", "puis-je", "comment puis-je", "ravi de",
             "je suis là", "je suis la", "aider aujourd", "assistant", "comment vas",
             "n'hésite", "n'hesite"]
    return not any(x in t for x in fluff)


# --- Agent sessions (Mode Her): stream events + human-in-the-loop permission gates ---
_AGENT_SESSIONS: dict = {}


class _AgentSession:
    def __init__(self):
        self.q: queue.Queue = queue.Queue()
        self._gate = threading.Event()
        self._decision = False
        self.allowed: set = set()      # scopes the user said "toujours" for THIS session
        self.auto_allow = False        # "mode confiance": auto-allow every non-Tier-3 scope
        self._pending_scope = None

    def emit(self, event: dict):
        self.q.put(event)

    def ask_permission(self, tool: str, args: dict, scope: str) -> bool:
        """Emit a gate event, then block until the user resumes (via /agent_resume).
        Allow silently if the scope was remembered ("toujours") OR if "mode confiance" is on —
        EXCEPT Tier-3 scopes (send/delete/screen), which ALWAYS require an explicit confirm."""
        from aneforge.agent import TIER3_SCOPES
        if scope and scope not in TIER3_SCOPES and (scope in self.allowed or self.auto_allow):
            return True
        self._pending_scope = scope
        self.emit({"type": "gate", "tool": tool, "args": args, "scope": scope})
        self._gate.clear()
        if not self._gate.wait(timeout=300):   # 5 min to decide, else deny
            return False
        return self._decision

    def resume(self, allow: bool, remember: bool = False):
        from aneforge.agent import TIER3_SCOPES
        if allow and remember and self._pending_scope and self._pending_scope not in TIER3_SCOPES:
            self.allowed.add(self._pending_scope)   # don't ask again this session
        self._decision = allow
        self._gate.set()


class Engine:
    """Holds the MLX model (loaded once) + per-model conversation history."""

    _MODEL_FILE = MODELS_DIR.parent / "model.txt"   # ~/.aneforge/model.txt — chosen local model

    def __init__(self, model_id: str | None = None):
        self.mlx = None
        self.model_id = model_id
        self.ready = False
        self.loading = None        # model id currently (re)loading, for the UI
        self._history: dict[str, list] = {}
        self._lock = threading.Lock()
        self._last_activity = 0.0
        self._consolidated: dict[str, int] = {}   # name → #user-turns already consolidated

    def warmup(self):
        from aneforge.mlx_chat import MLXChat, DEFAULT_MODEL
        if not self.model_id and self._MODEL_FILE.exists():
            self.model_id = self._MODEL_FILE.read_text().strip() or None   # remember the user's choice
        self.model_id = self.model_id or DEFAULT_MODEL
        self.mlx = MLXChat(self.model_id)
        self.ready = True
        threading.Thread(target=self._idle_loop, daemon=True).start()

    def set_model(self, model_id: str):
        """Switch the local model the user can change directly (Réglages). Downloads if needed;
        the old model keeps serving until the new one is loaded, then we swap atomically."""
        def _load():
            try:
                from aneforge.mlx_chat import MLXChat
                m = MLXChat(model_id)                      # may download (minutes); old model still serves
                with self._lock:
                    self.mlx = m
                    self.model_id = model_id
                self._MODEL_FILE.parent.mkdir(parents=True, exist_ok=True)
                self._MODEL_FILE.write_text(model_id)
            except Exception as e:
                print(f"[ember-daemon] set_model FAILED ({model_id}): {e}", flush=True)
            finally:
                self.loading = None
        if model_id == self.model_id and self.mlx is not None:
            return
        self.loading = model_id
        threading.Thread(target=_load, daemon=True).start()

    def _touch(self):
        self._last_activity = time.time()

    def _idle_loop(self):
        while True:
            time.sleep(15)
            if not self.ready or (time.time() - self._last_activity) < 25:
                continue
            for name in list(self._history.keys()):
                try:
                    self._consolidate(name)
                except Exception:
                    pass
            self._last_activity = time.time()   # don't re-run every loop while still idle

    def _consolidate(self, name: str):
        """Idle learning: re-read the conversation's user turns for durable facts that the
        per-message pass may have missed, grounded + deduped, then refresh a personal profile."""
        if not (MODELS_DIR / name).exists():
            return
        hist = self._history.get(name, [])
        users = [m["content"] for m in hist if m.get("role") == "user"]
        done = self._consolidated.get(name, 0)
        store = store_for_model(name)
        existing = [x.text for x in store.all()]
        for msg in users[done:]:
            if _looks_like_command(msg):
                continue
            try:
                for f in self._extract_facts(msg):
                    if _is_real_fact(f) and _grounded(f, msg) and not _is_near_dup(f, existing) \
                       and store.add(f, kind="misc", source="idle"):
                        existing.append(f)
            except Exception:
                continue
        self._consolidated[name] = len(users)
        # refresh a short personal profile from everything known (visible "learning")
        prof_path = MODELS_DIR / name / "profile.txt"
        if existing:
            try:
                facts = "\n".join(f"- {t}" for t in existing[:40])
                sysmsg = ("Résume en 2-3 phrases, à la 2e personne (« tu »), ce que l'on sait de "
                          "l'utilisateur à partir de ces faits. Reste fidèle, n'invente rien, garde "
                          "la langue des faits.")
                with self._lock:
                    profile = self.mlx.chat([{"role": "system", "content": sysmsg},
                                             {"role": "user", "content": facts}], max_tokens=160)
                prof_path.write_text(profile.strip())
            except Exception:
                pass
        elif prof_path.exists():
            prof_path.unlink()   # no facts → no stale garbage profile

    def _persona(self, name: str, prompt: str) -> str:
        s = _load_settings(name)
        # Identity guard — ALWAYS included (even with a custom persona): the small local model
        # otherwise sometimes claims to be "Claude"/another model. Language-neutral (§2.7): mirror
        # the user's language.
        identity = (
            f"You are Ember — the user's personal, on-device AI (this instance is named « {name} »). "
            "Your name is Ember. You are NOT Claude, GPT, Qwen, Llama, Gemini, or any other model or "
            "company's assistant — never say or imply otherwise. If asked who or what you are, you are "
            "simply Ember, the user's local AI. ALWAYS reply in the same language as the user's message.")
        lines = [s.get("persona") or "You are warm, concise and genuinely helpful.", identity]
        facts = store_for_model(name).relevant(prompt)
        if facts:
            lines.append(
                "Known facts about the USER. When the user asks about themselves (\"I\", \"my\", "
                "\"me\" — in any language), these facts are the answer; use them and never claim "
                "you don't know if a fact covers it. Keep the user's language.\n" +
                "\n".join(f"- {f.text}" for f in facts))
        return "\n\n".join(lines)

    def chat(self, name: str, prompt: str) -> dict:
        self._touch()
        store = store_for_model(name)

        # Reliable fact recall: answer straight from editable memory on a clear match.
        is_q = ("?" in prompt) or any(prompt.lower().lstrip().startswith(w) for w in _QWORDS)
        if is_q:
            fact = store.best_match(prompt)
            if fact is not None:
                self._history.setdefault(name, []).append({"role": "user", "content": prompt})
                self._history[name].append({"role": "assistant", "content": fact.text})
                return {"answer": fact.text, "learned": [], "source": "memory"}

        hist = self._history.setdefault(name, [])
        messages = [{"role": "system", "content": self._persona(name, prompt)}]
        messages += hist[-8:]
        messages.append({"role": "user", "content": prompt})

        max_tokens = int(_load_settings(name).get("max_tokens", 220) or 220)
        with self._lock:  # MLX model is not thread-safe; serialize generation
            answer = self.mlx.chat(messages, max_tokens=max_tokens)
        hist.append({"role": "user", "content": prompt})
        hist.append({"role": "assistant", "content": answer})

        # §4.D — fact extraction BY THE MODEL (any language), in the background so it never
        # delays the reply; serialized against generation via the same lock. Replaces the old
        # FR+EN regex (which violated §2.7).
        threading.Thread(target=self._learn_async, args=(name, prompt), daemon=True).start()
        return {"answer": answer, "learned": [], "source": "mlx"}

    def chat_stream(self, name: str, prompt: str):
        """Yield the reply token-by-token (§5.4). Same memory/recall/learning as chat()."""
        self._touch()
        store = store_for_model(name)
        is_q = ("?" in prompt) or any(prompt.lower().lstrip().startswith(w) for w in _QWORDS)
        if is_q:
            fact = store.best_match(prompt)
            if fact is not None:
                self._history.setdefault(name, []).append({"role": "user", "content": prompt})
                self._history[name].append({"role": "assistant", "content": fact.text})
                yield fact.text
                return

        hist = self._history.setdefault(name, [])
        messages = [{"role": "system", "content": self._persona(name, prompt)}]
        messages += hist[-8:]
        messages.append({"role": "user", "content": prompt})
        max_tokens = int(_load_settings(name).get("max_tokens", 220) or 220)
        full = ""
        with self._lock:  # serialize generation (MLX not thread-safe)
            for delta in self.mlx.stream(messages, max_tokens=max_tokens):
                full += delta
                yield delta
        hist.append({"role": "user", "content": prompt})
        hist.append({"role": "assistant", "content": full})
        threading.Thread(target=self._learn_async, args=(name, prompt), daemon=True).start()

    def _learn_async(self, name: str, message: str):
        if _looks_like_command(message):   # commands/requests/greetings aren't facts about the user
            return
        try:
            facts = self._extract_facts(message)
        except Exception:
            return
        if not facts:
            return
        store = store_for_model(name)  # fresh connection for this thread
        existing = [x.text for x in store.all()]
        for f in facts:
            # §2.4 honesty: keep ONLY real, grounded, non-duplicate facts about the USER.
            # (_is_real_fact drops command echoes / assistant fluff; _grounded drops the small
            # model's embellishments; _is_near_dup drops paraphrases.)
            if not _is_real_fact(f) or not _grounded(f, message) or _is_near_dup(f, existing):
                continue
            if store.add(f, kind="misc", source="model"):
                existing.append(f)

    def _extract_facts(self, message: str) -> list[str]:
        sys = ("Extract durable personal facts the user EXPLICITLY states about THEMSELVES "
               "(name, age, location, job, relationships, tastes, ongoing projects).\n"
               "STRICT RULES:\n"
               "- Output ONLY a JSON array of short THIRD-PERSON statements in the user's language.\n"
               "- Use ONLY words/entities present in the message. NEVER invent or add a name, place, "
               "pet, age, project, job or any detail that is not literally written. If unsure, omit it.\n"
               "- ATOMIC: exactly one fact per item; never join with 'et'/'and'/','.\n"
               "- Each item is a short third-person clause reusing the message's own words.\n"
               "- No duplicates, no questions/requests/greetings, no transient info. At most 4 facts.\n"
               "- If the message states no durable personal fact (e.g. a question or a request), "
               "reply with an empty array and nothing else.\n"
               "Example — message \"je m'appelle Théo et je vis à Nantes\" gives "
               "[\"S'appelle Théo\",\"Vit à Nantes\"]; message \"quelle heure est-il ?\" gives [].")
        msgs = [{"role": "system", "content": sys}, {"role": "user", "content": message}]
        with self._lock:
            raw = self.mlx.chat(msgs, max_tokens=100)
        return _parse_fact_array(raw)

    def ingest(self, name: str, text: str) -> int:
        """§4.A — learn from a file by extracting facts into memory (reliable recall),
        not by fine-tuning weights (§9.A: collapse-prone on a small local model)."""
        store = store_for_model(name)
        existing = [x.text for x in store.all()]
        learned = 0
        for chunk in _chunk_text(text):
            try:
                for f in self._extract_facts(chunk):
                    # §2.4 honesty: never store a fact the model invented — keep it only if its
                    # content is actually grounded in the source chunk, and isn't a paraphrase
                    # of something we already know.
                    if not _is_real_fact(f) or not _grounded(f, chunk) or _is_near_dup(f, existing):
                        continue
                    if store.add(f, kind="misc", source="file"):
                        existing.append(f); learned += 1
            except Exception:
                continue
        return learned

    def reset(self, name: str):
        self._history.pop(name, None)

    # --- Mode Her: route a spoken/typed message to CONVERSATION (local chat) or WORK (agent) ---
    def route(self, message: str) -> str:
        """Conversation-first: only hand off to the DeepSeek work-agent on a clear request to
        DO something on the computer; otherwise Ember just talks (local, private)."""
        m = (message or "").strip()
        if not m:
            return "chat"
        sys = ("Route the user's message for a personal AI on their Mac. "
               "TASK = they ask Ember to DO something concrete with the computer: read/list files "
               "or folders, write or draft a note/message, search their files or memory, summarize "
               "a document, prepare something. CHAT = everything else (greetings, small talk, "
               "questions about themselves or the world, opinions, feelings). "
               "Answer with ONE word: TASK or CHAT.")
        try:
            with self._lock:
                out = self.mlx.chat([{"role": "system", "content": sys},
                                     {"role": "user", "content": m}], max_tokens=4)
            return "task" if "task" in (out or "").lower() else "chat"
        except Exception:
            return "chat"


def make_handler(engine: Engine):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # quiet
            pass

        def _send(self, code, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length", 0) or 0)
            return json.loads(self.rfile.read(n) or b"{}")

        def do_GET(self):
            u = urlparse(self.path)
            if u.path == "/health":
                from aneforge.agent import available as _agent_available
                return self._send(200, {"ok": True, "model": engine.model_id, "ready": engine.ready,
                                        "loading": engine.loading, "has_key": _agent_available()})
            if u.path == "/models":
                return self._send(200, [
                    {"name": m["name"], "base": m["base_model"], "version": m["version"],
                     "steps": m["total_training_steps"]}
                    for m in PersonalModel.list_models()])
            if u.path == "/memory":
                name = (parse_qs(u.query).get("name") or [""])[0]
                facts = store_for_model(name).all() if (MODELS_DIR / name).exists() else []
                return self._send(200, [{"id": f.id, "kind": f.kind, "text": f.text, "source": f.source} for f in facts])
            if u.path == "/settings":
                name = (parse_qs(u.query).get("name") or [""])[0]
                return self._send(200, _load_settings(name))
            if u.path == "/profile":
                # the personal profile Ember refreshes while idle (§4.D continued learning)
                name = (parse_qs(u.query).get("name") or [""])[0]
                p = MODELS_DIR / name / "profile.txt"
                return self._send(200, {"profile": p.read_text().strip() if p.exists() else ""})
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            try:
                b = self._body()
                if u.path == "/create":
                    name = b["name"]
                    if not (MODELS_DIR / name).exists():
                        PersonalModel.create(name, base=b.get("base", "smollm2-360m-instruct"))
                    return self._send(200, {"ok": True})
                if u.path == "/delete":
                    if (MODELS_DIR / b["name"]).exists():
                        PersonalModel(b["name"]).delete(confirm=True)
                    engine.reset(b["name"])
                    return self._send(200, {"ok": True})
                if u.path == "/rename":
                    old = b["name"]; new = (b.get("new") or "").strip()
                    if not new:
                        return self._send(400, {"error": "nom vide"})
                    src = MODELS_DIR / old; dst = MODELS_DIR / new
                    if not src.exists():
                        return self._send(404, {"error": "introuvable"})
                    if dst.exists():
                        return self._send(409, {"error": "ce nom est déjà pris"})
                    import shutil
                    shutil.move(str(src), str(dst))   # moves config, settings.json, memory.db, versions
                    # the listing reads name from config.json — update it so the rename shows up
                    cfg = dst / "config.json"
                    try:
                        data = json.loads(cfg.read_text())
                        data["name"] = new
                        cfg.write_text(json.dumps(data))
                    except Exception:
                        pass
                    engine.reset(old)
                    return self._send(200, {"ok": True})
                if u.path == "/chat":
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    if not (MODELS_DIR / b["name"]).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    return self._send(200, engine.chat(b["name"], b["prompt"]))
                if u.path == "/route":
                    # Mode Her: decide conversation (local chat) vs work (agent). §4.E
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    return self._send(200, {"mode": engine.route(b.get("message") or b.get("prompt") or "")})
                if u.path == "/tts":
                    # Ember's local neural voice (Kokoro). Returns WAV bytes, or 415 so the
                    # app falls back to the OS voice if the stack/lang is unavailable.
                    text = b.get("text") or ""
                    lang = b.get("lang") or "fr"
                    if not tts.available():
                        return self._send(415, {"error": "voix neuronale indisponible"})
                    try:
                        wav = tts.synth_wav_bytes(text, lang)
                    except Exception as e:
                        return self._send(500, {"error": f"tts: {e}"})
                    if not wav:
                        return self._send(204, {})
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/wav")
                    self.send_header("Content-Length", str(len(wav)))
                    self.end_headers()
                    self.wfile.write(wav)
                    return
                if u.path == "/ingest":
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    if not (MODELS_DIR / b["name"]).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    learned = engine.ingest(b["name"], b.get("text") or "")
                    return self._send(200, {"ok": True, "learned": learned})
                if u.path == "/chat_stream":
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    name, prompt = b["name"], b["prompt"]   # KeyError here → outer 500 (pre-headers)
                    if not (MODELS_DIR / name).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    try:
                        for delta in engine.chat_stream(name, prompt):
                            self.wfile.write(delta.encode("utf-8"))
                            self.wfile.flush()
                    except Exception:
                        pass
                    return
                if u.path == "/agent_stream":
                    from aneforge.agent import run_agent, available
                    if not available():
                        return self._send(503, {"error": "agent indisponible (clé DeepSeek absente)"})
                    name = b["name"]
                    task = b.get("task") or b.get("prompt") or ""
                    sid = b.get("session") or uuid.uuid4().hex
                    sess = _AgentSession()
                    sess.auto_allow = bool(b.get("trust"))   # "mode confiance" → no prompt (non-Tier-3)
                    _AGENT_SESSIONS[sid] = sess
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    self.wfile.write((json.dumps({"type": "session", "id": sid}) + "\n").encode())
                    self.wfile.flush()

                    def _worker():
                        try:
                            run_agent(name, task, sess.emit, sess.ask_permission)
                        except Exception as e:
                            sess.emit({"type": "error", "text": str(e)})
                        sess.emit({"type": "_end"})
                    threading.Thread(target=_worker, daemon=True).start()
                    try:
                        while True:
                            e = sess.q.get()
                            if e.get("type") == "_end":
                                break
                            self.wfile.write((json.dumps(e, ensure_ascii=False) + "\n").encode())
                            self.wfile.flush()
                    except Exception:
                        pass
                    _AGENT_SESSIONS.pop(sid, None)
                    return
                if u.path == "/agent_resume":
                    sess = _AGENT_SESSIONS.get(b.get("session"))
                    if sess:
                        sess.resume(bool(b.get("allow")), bool(b.get("remember")))
                    return self._send(200, {"ok": True})
                if u.path == "/add_fact":
                    # explicit fact the USER typed in Mémoire → store it VERBATIM. No grounding
                    # / hallucination filter here: the user stated it deliberately, it is not the
                    # small model's guess. Dedup is automatic (UNIQUE text constraint → add()=None).
                    name = b["name"]; text = (b.get("text") or "").strip()
                    if not (MODELS_DIR / name).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    if not text:
                        return self._send(400, {"error": "texte vide"})
                    f = store_for_model(name).add(text, kind=(b.get("kind") or "misc"), source="explicit")
                    return self._send(200, {"ok": True, "added": bool(f), "id": (f.id if f else None)})
                if u.path == "/search":
                    # Mémoire search box — hybrid keyword + multilingual-semantic ranking.
                    name = b["name"]; q = b.get("q") or b.get("query") or ""
                    if not (MODELS_DIR / name).exists():
                        return self._send(200, [])
                    facts = store_for_model(name).search(q)
                    return self._send(200, [{"id": f.id, "kind": f.kind, "text": f.text,
                                             "source": f.source} for f in facts])
                if u.path == "/forget":
                    s = store_for_model(b["name"])
                    removed = s.clear() if b.get("all") else (1 if s.delete(int(b["id"])) else 0)
                    return self._send(200, {"ok": True, "removed": removed})
                if u.path == "/reset":
                    engine.reset(b["name"]); return self._send(200, {"ok": True})
                if u.path == "/settings":
                    _save_settings(b["name"], b.get("persona", ""), int(b.get("max_tokens", 220)))
                    return self._send(200, {"ok": True})
                if u.path == "/set_model":
                    # change the LOCAL model directly (Réglages) — reloads it (downloads if needed)
                    engine.set_model((b.get("model") or "").strip())
                    return self._send(200, {"ok": True, "loading": engine.loading})
                if u.path == "/set_key":
                    # set/clear the DeepSeek API key for the Mode Her work-agent (never hard-coded)
                    key = (b.get("key") or "").strip()
                    p = MODELS_DIR.parent / "deepseek.key"
                    p.parent.mkdir(parents=True, exist_ok=True)
                    if key:
                        p.write_text(key)
                    elif p.exists():
                        p.unlink()
                    return self._send(200, {"ok": True, "has_key": bool(key)})
                return self._send(404, {"error": "not found"})
            except Exception as e:
                return self._send(500, {"error": str(e)})
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--model", default=None)
    args = ap.parse_args()

    engine = Engine(args.model)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(engine))
    print(f"[ember-daemon] http://127.0.0.1:{args.port} — loading model…", flush=True)
    # Load the model in the background so /health responds immediately.
    threading.Thread(target=lambda: (_warm(engine)), daemon=True).start()
    srv.serve_forever()


def _warm(engine: Engine):
    try:
        engine.warmup()
        print(f"[ember-daemon] model ready: {engine.model_id}", flush=True)
    except Exception as e:
        print(f"[ember-daemon] model load FAILED: {e}", flush=True)
    # Warm Ember's neural voice in the background too, so the first spoken reply is instant.
    try:
        if tts.available():
            tts.warmup()
            print("[ember-daemon] voice ready: Kokoro", flush=True)
    except Exception as e:
        print(f"[ember-daemon] voice warmup skipped: {e}", flush=True)


if __name__ == "__main__":
    main()
