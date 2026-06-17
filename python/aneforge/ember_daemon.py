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
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from aneforge.personal import PersonalModel, MODELS_DIR
from aneforge.memory import store_for_model

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
    """Pull a JSON array of short fact strings out of the model's reply (robust to extra text)."""
    if not raw:
        return []
    s = raw.strip()
    a, b = s.find("["), s.rfind("]")
    if a < 0 or b <= a:
        return []
    try:
        arr = json.loads(s[a:b + 1])
    except Exception:
        return []
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
        for f in facts:
            store.add(f, kind="misc", source="model")

    def _extract_facts(self, message: str) -> list[str]:
        sys = ("You are a fact extractor. From the user's message, extract DURABLE personal facts "
               "the user states about THEMSELVES (name, age, location, job, relationships, "
               "tastes/preferences, ongoing projects). Reply with ONLY a JSON array of short "
               "third-person statements IN THE USER'S LANGUAGE, e.g. "
               '["Habite à Lyon","A un chat nommé Marlow"]. List each distinct fact ONCE — never '
               "repeat or paraphrase the same fact. At most 5. No questions, no requests, no "
               "transient/trivial info, no extra text. If there are none, reply []." )
        msgs = [{"role": "system", "content": sys}, {"role": "user", "content": message}]
        with self._lock:
            raw = self.mlx.chat(msgs, max_tokens=160)
        return _parse_fact_array(raw)

    def ingest(self, name: str, text: str) -> int:
        """§4.A — learn from a file by extracting facts into memory (reliable recall),
        not by fine-tuning weights (§9.A: collapse-prone on a small local model)."""
        store = store_for_model(name)
        learned = 0
        for chunk in _chunk_text(text):
            try:
                for f in self._extract_facts(chunk):
                    # §2.4 honesty: never store a fact the model invented — keep it only if its
                    # content is actually grounded in the source chunk.
                    if _grounded(f, chunk) and store.add(f, kind="misc", source="file"):
                        learned += 1
            except Exception:
                continue
        return learned

    def reset(self, name: str):
        self._history.pop(name, None)


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
                    engine.reset(old)
                    return self._send(200, {"ok": True})
                if u.path == "/chat":
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    return self._send(200, engine.chat(b["name"], b["prompt"]))
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


if __name__ == "__main__":
    main()
