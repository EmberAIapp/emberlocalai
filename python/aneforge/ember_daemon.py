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
    """True if most of the fact's content words appear in the source — rejects model hallucinations."""
    fw = [w for w in re.findall(r"[^\W\d_]+", fact.lower(), re.UNICODE) if len(w) > 3]
    if not fw:
        return False
    sl = source.lower()
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


# --- Agent sessions (Mode Her): stream events + human-in-the-loop permission gates ---
_AGENT_SESSIONS: dict = {}


class _AgentSession:
    def __init__(self):
        self.q: queue.Queue = queue.Queue()
        self._gate = threading.Event()
        self._decision = False
        self.allowed: set = set()      # scopes the user said "toujours" for THIS session
        self._pending_scope = None

    def emit(self, event: dict):
        self.q.put(event)

    def ask_permission(self, tool: str, args: dict, scope: str) -> bool:
        """Emit a gate event, then block until the user resumes (via /agent_resume).
        If the user already chose "toujours" for this scope this session, allow silently
        (mains libres — no repeated prompt). Tier-3 scopes (send/delete) are never remembered."""
        if scope and scope in self.allowed:
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

    def __init__(self, model_id: str | None = None):
        self.mlx = None
        self.model_id = model_id
        self.ready = False
        self._history: dict[str, list] = {}
        self._lock = threading.Lock()

    def warmup(self):
        from aneforge.mlx_chat import MLXChat, DEFAULT_MODEL
        self.model_id = self.model_id or DEFAULT_MODEL
        self.mlx = MLXChat(self.model_id)
        self.ready = True

    def _persona(self, name: str, prompt: str) -> str:
        s = _load_settings(name)
        # Language-neutral default (no hard-coded French — §2.7): instruct the model to
        # mirror the user's language so Ember answers FR→FR, EN→EN, ES→ES, etc.
        lines = [s.get("persona") or
                 ("You are Ember, the user's 100% local personal AI. You are warm, concise, "
                  "and you ALWAYS reply in the same language as the user's message.")]
        facts = store_for_model(name).relevant(prompt)
        if facts:
            lines.append(
                "Known facts about the USER. When the user asks about themselves (\"I\", \"my\", "
                "\"me\" — in any language), these facts are the answer; use them and never claim "
                "you don't know if a fact covers it. Keep the user's language.\n" +
                "\n".join(f"- {f.text}" for f in facts))
        return "\n\n".join(lines)

    def chat(self, name: str, prompt: str) -> dict:
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
        try:
            facts = self._extract_facts(message)
        except Exception:
            return
        if not facts:
            return
        store = store_for_model(name)  # fresh connection for this thread
        existing = [x.text for x in store.all()]
        for f in facts:
            # §2.4 honesty: a small model embellishes (it invents age, job, extra tastes…).
            # Keep ONLY facts grounded in what the user actually wrote — the same
            # anti-hallucination gate already used for file ingestion. Without this, chat
            # silently stored invented "facts about you", which is worse than forgetting.
            if not _grounded(f, message):
                continue
            if _is_near_dup(f, existing):   # skip paraphrases of what we already know
                continue
            if store.add(f, kind="misc", source="model"):
                existing.append(f)

    def _extract_facts(self, message: str) -> list[str]:
        sys = ("You extract durable personal facts the user EXPLICITLY states about THEMSELVES "
               "(name, age, location, job, relationships, tastes, ongoing projects). Rules:\n"
               "- Output ONLY a JSON array of short THIRD-PERSON statements in the user's "
               'language, e.g. ["Habite à Lyon","A un chat nommé Marlow"].\n'
               "- ATOMIC: exactly one fact per item. NEVER join two facts with 'et'/'and'/','.\n"
               "- Use ONLY information written in the message. NEVER infer, guess, add or "
               "embellish any detail (age, job, tastes…) that is not literally stated.\n"
               "- No duplicate or paraphrased facts. No questions, requests, dates, greetings, "
               "or transient/trivial info. At most 5 facts.\n"
               "- If the message states no durable personal fact, reply exactly []." )
        msgs = [{"role": "system", "content": sys}, {"role": "user", "content": message}]
        with self._lock:
            raw = self.mlx.chat(msgs, max_tokens=160)
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
                    if not _grounded(f, chunk) or _is_near_dup(f, existing):
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
                return self._send(200, {"ok": True, "model": engine.model_id, "ready": engine.ready})
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
                if u.path == "/forget":
                    s = store_for_model(b["name"])
                    removed = s.clear() if b.get("all") else (1 if s.delete(int(b["id"])) else 0)
                    return self._send(200, {"ok": True, "removed": removed})
                if u.path == "/reset":
                    engine.reset(b["name"]); return self._send(200, {"ok": True})
                if u.path == "/settings":
                    _save_settings(b["name"], b.get("persona", ""), int(b.get("max_tokens", 220)))
                    return self._send(200, {"ok": True})
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
