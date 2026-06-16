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
        lines = [s.get("persona") or
                 ("Tu es Ember, l'assistant personnel local de l'utilisateur. "
                  "Tu es chaleureux, concis, et tu réponds dans la langue de l'utilisateur.")]
        facts = store_for_model(name).relevant(prompt)
        if facts:
            lines.append("Ce que tu sais sur l'utilisateur :\n" +
                         "\n".join(f"- {f.text}" for f in facts))
        return "\n\n".join(lines)

    def chat(self, name: str, prompt: str) -> dict:
        store = store_for_model(name)
        learned = store.extract_and_store(prompt)

        # Reliable fact recall: answer from editable memory when it clearly matches.
        is_q = ("?" in prompt) or any(prompt.lower().lstrip().startswith(w) for w in _QWORDS)
        if is_q and not learned:
            fact = store.best_match(prompt)
            if fact is not None:
                self._history.setdefault(name, []).append({"role": "user", "content": prompt})
                self._history[name].append({"role": "assistant", "content": fact.text})
                return {"answer": fact.text, "learned": [f.text for f in learned], "source": "memory"}

        hist = self._history.setdefault(name, [])
        messages = [{"role": "system", "content": self._persona(name, prompt)}]
        messages += hist[-8:]
        messages.append({"role": "user", "content": prompt})

        max_tokens = int(_load_settings(name).get("max_tokens", 220) or 220)
        with self._lock:  # MLX model is not thread-safe; serialize generation
            answer = self.mlx.chat(messages, max_tokens=max_tokens)
        hist.append({"role": "user", "content": prompt})
        hist.append({"role": "assistant", "content": answer})
        return {"answer": answer, "learned": [f.text for f in learned], "source": "mlx"}

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
                if u.path == "/chat":
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    return self._send(200, engine.chat(b["name"], b["prompt"]))
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
