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
import os
import queue
import re
import threading
import time
import uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from aneforge.personal import PersonalModel, MODELS_DIR
from aneforge.memory import store_for_model, classify_kind
from aneforge import tts

_QWORDS = ("comment", "quel", "quelle", "qui", "où", "ou ", "quand", "what",
           "who", "where", "when", "how", "is ", "est-ce", "pourquoi")

# Imperative "compose original text" requests — the tiny local model writes these badly, so we
# hand them to the cloud work-agent (DeepSeek, with consent) for real quality. High-precision
# EN/FR pre-check; the few-shot model classifier is the fallback for everything else / other langs.
_CREATE_RE = re.compile(
    r"\b(write|compose|draft|create|generate|"
    r"[ée]cri(?:s|re|ve)|r[ée]dige[rz]?|composer?|g[ée]n[èe]re[rz]?|invente[rz]?|raconte[rz]?)\b"
    r".{0,40}?\b(poems?|po[èe]mes?|haikus?|ha[ïi]kus?|story|stories|histoires?|contes?|songs?|"
    r"chansons?|lyrics|paroles|messages?|notes?|e-?mails?|mails?|letters?|lettres?|essays?|essais?|"
    r"speech|discours|jokes?|blagues?|texte?s?|paragraphe?s?|tweets?|captions?|slogans?|scripts?|"
    r"sc[ée]narios?|po[èe]sies?)\b",
    re.IGNORECASE)

# Clear computer/file/app actions → also the agent (the local model can't touch files). An action
# verb near a computer/media object (EN/FR), incl. music, reminders, calendar, clipboard.
_ACTION_RE = re.compile(
    r"\b(open|launch|run|play|pause|list|show|display|find|search|locate|read|summari[sz]e|save|"
    r"send|move|copy|rename|organi[sz]e|delete|download|remind|schedule|add|create|set|"
    r"ouvre|ouvrir|lance|lancer|d[ée]marre|ex[ée]cute|joue[rz]?|mets|coupe|liste[rz]?|affiche[rz]?|"
    r"montre[rz]?|cherche[rz]?|trouve[rz]?|recherche[rz]?|r[ée]sume[rz]?|enregistre|sauvegarde|"
    r"envoie[rz]?|d[ée]place|copie|renomme|organise|range|supprime|t[ée]l[ée]charge|rappelle|"
    r"planifie|ajoute|cr[ée]e)\b"
    r".{0,40}?\b(files?|folders?|documents?|desktop|apps?|application|notes?|e-?mails?|messages?|"
    r"finder|downloads?|screen|window|calendar|reminders?|music|songs?|tracks?|playlists?|"
    r"events?|meetings?|appointments?|clipboard|"
    r"fichiers?|dossiers?|bureau|t[ée]l[ée]chargements?|courriels?|messagerie|[ée]cran|fen[êe]tre|"
    r"calendrier|rappels?|musique|chansons?|morceaux?|[ée]v[ée]nements?|rendez-vous|r[ée]unions?|"
    r"presse-papiers)\b",
    re.IGNORECASE)
# "open/launch X" (an app) is always a task, whatever X is.
_LAUNCH_RE = re.compile(r"\b(open|launch|ouvre|ouvrir|lance|lancer|d[ée]marre)\b\s+\S", re.IGNORECASE)
# A message that STARTS with an action/imperative verb is a task ("ouvre…", "mets de la musique",
# "crée un rappel", "rappelle-moi…", "joue…", "envoie…"). Missing a task is SILENT and worse than an
# extra consent gate, so we lean toward TASK for imperatives; greetings/questions don't start with
# these verbs → they still go to chat.
_IMPERATIVE_RE = re.compile(
    r"^\s*(?:s'?il te pla[iî]t,?\s+|stp,?\s+|please,?\s+|peux[- ]?tu\s+|pourrais[- ]?tu\s+|"
    r"tu peux\s+|tu pourrais\s+|vas[- ]?y,?\s+|can you\s+|could you\s+|would you\s+|"
    r"je\s+(?:veux|voudrais|aimerais|ai\s+besoin)(?:\s+que\s+tu)?\s+|i (?:want|need|'?d like)(?: you)? to\s+)?"
    r"(?:m['’]|me\s+|moi\s+|nous\s+|le\s+|la\s+|les\s+|lui\s+)?\s*"
    r"(open|launch|run|play|pause|stop|skip|next|previous|resume|list|show|display|find|search|"
    r"read|summari[sz]e|save|send|move|copy|paste|rename|organi[sz]e|delete|download|remind|"
    r"schedule|add|create|make|set|put|write|compose|draft|translate|calculate|"
    r"ouvr\w*|lanc\w*|d[ée]marr\w*|ex[ée]cut\w*|jou\w*|mets|mettre|coup\w*|arr[êe]t\w*|repren\w*|"
    r"pass\w*|list\w*|affich\w*|montr\w*|cherch\w*|trouv\w*|recherch\w*|lis|lire|r[ée]sum\w*|"
    r"enregistr\w*|sauvegard\w*|envoi\w*|d[ée]plac\w*|copi\w*|coll\w*|renomm\w*|organis\w*|rang\w*|"
    r"supprim\w*|t[ée]l[ée]charg\w*|rappell\w*|planifi\w*|ajout\w*|cr[ée]\w*|fai(?:s|t|re|tes)|"
    r"[ée]cri\w*|r[ée]dig\w*|compos\w*|traduis\w*|calcul\w*|programm\w*)\b",
    re.IGNORECASE)


def _settings_path(name: str):
    return MODELS_DIR / name / "settings.json"


def _load_settings(name: str) -> dict:
    base = {"persona": "", "max_tokens": 220, "temperature": 0.7, "tone": "Calm"}
    p = _settings_path(name)
    if p.exists():
        try:
            base.update(json.loads(p.read_text()))   # merge → all keys always present
        except Exception:
            pass
    return base


def _save_settings(name: str, persona: str, max_tokens: int, temperature: float = 0.7, tone: str = "Calm"):
    _settings_path(name).write_text(json.dumps(
        {"persona": persona, "max_tokens": max_tokens, "temperature": temperature,
         "tone": _canon_tone(tone)}))   # store a canonical label → the UI chip always matches back


# Tone chip (Réglages / Onboarding) → a REAL instruction injected into the system prompt.
# The SwiftUI app sends English labels (DesignData.personaOptions); older settings.json files may
# still hold the legacy French labels. Both resolve via _canon_tone → the chip is never inert.
_TONE_INSTR = {
    "Lively":       "Adopt a lively, direct and energetic tone.",
    "Professional": "Adopt a professional, precise and structured tone.",
    "Warm":         "Adopt a warm, caring and close tone.",
    "Calm":         "Adopt a calm, composed and reassuring tone.",
}
# Any label the UI or a legacy file might carry → its canonical key above (case-insensitive).
_TONE_ALIASES = {
    "lively": "Lively", "vif": "Lively",
    "professional": "Professional", "professionnel": "Professional",
    "warm": "Warm", "chaleureux": "Warm",
    "calm": "Calm", "calme": "Calm",
}


def _canon_tone(tone: str) -> str:
    """Map any tone label (English UI, legacy French, any case) to a canonical key; default Calm."""
    return _TONE_ALIASES.get((tone or "").strip().lower(), "Calm")


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


def _primary_arg(args: dict) -> str:
    """The identifying argument of a tool call (path/file/query/…) — used to remember
    permission PER-PATH, not per whole scope (so 'Toujours' on one file doesn't open all)."""
    if not isinstance(args, dict):
        return ""
    for k in ("path", "filename", "file", "dir", "directory", "query", "pattern",
              "name", "url", "title", "subject"):
        v = args.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


class _AgentSession:
    def __init__(self):
        self.q: queue.Queue = queue.Queue()
        self._gate = threading.Event()
        self._decision = False
        self._stop = threading.Event()  # « Stop » côté serveur → plus aucun outil n'est exécuté
        self.allowed: set = set()      # remembered "toujours" keys for THIS session (scope OR scope+path)
        self.auto_allow = False        # "mode confiance": auto-allow every non-Tier-3 scope
        self.cloud_consented = False   # cloud handshake granted for THIS session (trust mode) → no re-ask
        self.blocked: set = set()      # scopes the user turned OFF in Réglages → HARD-denied
        self._pending_key = None

    def emit(self, event: dict):
        self.q.put(event)

    def stop(self):
        """Demande d'arrêt : le worker s'arrête avant le prochain outil ; débloque une permission en attente."""
        self._stop.set()
        self._gate.set()

    def stopped(self) -> bool:
        return self._stop.is_set()

    def ask_permission(self, tool: str, args: dict, scope: str) -> bool:
        """Emit a gate event, then block until the user resumes (via /agent_resume).
        Allow silently if THIS scope+path was remembered ("toujours") OR if "mode confiance" is on —
        EXCEPT Tier-3 scopes (cloud egress, send/delete/screen…), which ALWAYS confirm explicitly.
        Remembering is keyed by scope+PATH so authorising one file never opens every file."""
        from aneforge.agent import TIER3_SCOPES, CLOUD_SCOPE
        if self._stop.is_set():
            return False                # arrêté → on ne demande même pas, on refuse
        # Réglages : un périmètre désactivé est REFUSÉ d'office (révocable, granulaire).
        if scope and scope in self.blocked:
            self.emit({"type": "observation", "name": tool,
                       "text": f"Refusé : « {scope} » est désactivé dans tes Réglages.", "denied": True})
            return False
        # Mode autorisation automatique : en mode confiance, l'utilisateur accorde la poignée de main
        # cloud UNE fois par session → ensuite l'agent enchaîne sans la redemander. Toutes les AUTRES
        # actions Tier-3 (raccourcis, envoi, suppression, lecture presse-papiers, écran) reconfirment
        # toujours, et un périmètre bloqué dans Réglages reste refusé (vérifié juste au-dessus).
        if scope == CLOUD_SCOPE and (self.cloud_consented or CLOUD_SCOPE in self.allowed):
            return True
        arg = _primary_arg(args)
        path_key = f"{scope}\x1f{arg}" if arg else scope
        if scope and scope not in TIER3_SCOPES:
            if self.auto_allow or scope in self.allowed or path_key in self.allowed:
                return True
        self._pending_key = (scope, path_key)
        self.emit({"type": "gate", "tool": tool, "args": args, "scope": scope})
        self._gate.clear()
        if not self._gate.wait(timeout=300):   # 5 min to decide, else deny
            return False
        if self._stop.is_set():                # arrêté pendant l'attente → refus
            return False
        return self._decision

    def resume(self, allow: bool, remember: bool = False):
        from aneforge.agent import TIER3_SCOPES
        if allow and remember and self._pending_key:
            scope, path_key = self._pending_key
            if scope and scope not in TIER3_SCOPES:
                self.allowed.add(path_key)   # remember THIS path only, not the whole scope
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

    @staticmethod
    def _is_cached(model_id: str) -> bool:
        """True if the model is already present in the local HF cache (→ no network download)."""
        hf = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
        safe = "models--" + model_id.replace("/", "--")
        return (Path(hf) / "hub" / safe).exists() or (Path(hf) / safe).exists()

    def set_model(self, model_id: str):
        """Switch the local model the user can change directly (Réglages). For a 100%-local deploy we
        only switch to a model ALREADY downloaded — never trigger a silent network download. A new
        model must be fetched explicitly (out of band), not as a hidden side effect of a UI toggle."""
        if model_id == self.model_id and self.mlx is not None:
            return
        if not self._is_cached(model_id):
            print(f"[ember-daemon] set_model REFUSED ({model_id}): non téléchargé "
                  f"(pas de téléchargement silencieux).", flush=True)
            self.loading = None
            return
        def _load():
            try:
                from aneforge.mlx_chat import MLXChat
                m = MLXChat(model_id)                      # already cached → loads offline
                with self._lock:
                    self.mlx = m
                    self.model_id = model_id
                self._MODEL_FILE.parent.mkdir(parents=True, exist_ok=True)
                self._MODEL_FILE.write_text(model_id)
            except Exception as e:
                print(f"[ember-daemon] set_model FAILED ({model_id}): {e}", flush=True)
            finally:
                self.loading = None
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
                       and store.add(f, kind=classify_kind(f), source="idle"):
                        existing.append(f)
            except Exception:
                continue
        self._consolidated[name] = len(users)
        # refresh a short personal profile from everything known (visible "learning")
        prof_path = MODELS_DIR / name / "profile.txt"
        if existing:
            try:
                facts = "\n".join(f"- {t}" for t in existing[:40])
                sysmsg = ("In 2-3 sentences, addressing the user as \"you\", summarise what is "
                          "known about this user from these facts. Stay faithful, invent nothing, "
                          "and write in the SAME LANGUAGE as the facts.")
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
        tone = _TONE_INSTR.get(_canon_tone(s.get("tone")), "")
        base_persona = s.get("persona") or "You are warm, concise and genuinely helpful."
        # The small local model otherwise sometimes REFUSES harmless creative asks ("I'm just an
        # AI, I can't write a poem…"). Make explicit that Ember writes/creates on request.
        capable = ("You can write, draft, brainstorm and create on request — poems, messages, ideas, "
                   "lists, short texts. When asked to write or make something, just do it, directly "
                   "and warmly. Never refuse a harmless request, never say you \"can't\", never break "
                   "character.")
        lines = [" ".join(x for x in (tone, base_persona) if x), capable, identity]
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

        cfg = _load_settings(name)
        max_tokens = int(cfg.get("max_tokens", 220) or 220)
        temperature = float(cfg.get("temperature", 0.7))
        with self._lock:  # MLX model is not thread-safe; serialize generation
            answer = self.mlx.chat(messages, max_tokens=max_tokens, temperature=temperature)
        hist.append({"role": "user", "content": prompt})
        hist.append({"role": "assistant", "content": answer})

        # §4.D — fact extraction BY THE MODEL (any language), in the background so it never
        # delays the reply; serialized against generation via the same lock. Replaces the old
        # FR+EN regex (which violated §2.7).
        threading.Thread(target=self._learn_async, args=(name, prompt), daemon=True).start()
        return {"answer": answer, "learned": [], "source": "mlx"}

    def generate(self, name: str, brief: str) -> dict:
        """§1/§5.4 plus-value — GÉNÉRER un vrai élément (document) EN LOCAL, ancré dans la persona
        + la mémoire de l'utilisateur. Renvoie le contenu Markdown complet + un titre. 100% local."""
        cfg = _load_settings(name)
        sysmsg = (self._persona(name, brief) +
                  "\n\nL'utilisateur te demande de GÉNÉRER un document/élément. Produis le contenu "
                  "FINAL, COMPLET et bien structuré en Markdown (un titre #, des sections, des listes "
                  "si utile). N'écris QUE le contenu — aucun préambule du type « Voici… ». "
                  "Réponds dans la langue de l'utilisateur.")
        messages = [{"role": "system", "content": sysmsg}, {"role": "user", "content": brief}]
        with self._lock:
            content = self.mlx.chat(messages, max_tokens=900,
                                    temperature=float(cfg.get("temperature", 0.7)),
                                    repetition_penalty=1.18)
        # Title = first Markdown heading, else first words of the brief.
        title = ""
        for line in content.splitlines():
            t = line.strip().lstrip("#").strip()
            if t:
                title = t[:60]; break
        if not title:
            title = " ".join(brief.split()[:7])[:60] or "Document"
        return {"ok": True, "content": content.strip(), "title": title}

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
        cfg = _load_settings(name)
        max_tokens = int(cfg.get("max_tokens", 220) or 220)
        temperature = float(cfg.get("temperature", 0.7))
        full = ""
        with self._lock:  # serialize generation (MLX not thread-safe)
            for delta in self.mlx.stream(messages, max_tokens=max_tokens, temperature=temperature):
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
            if store.add(f, kind=classify_kind(f), source="model"):
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

    def ingest(self, name: str, text: str, source: str = "file") -> int:
        """§4.A — learn from a file by extracting facts into memory (reliable recall),
        not by fine-tuning weights (§9.A: collapse-prone on a small local model).
        `source` tags each fact with its origin (e.g. the file path) so the user can later
        FORGET exactly what a given connector/source taught (CRUD on learning)."""
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
                    if store.add(f, kind=classify_kind(f), source=source):
                        existing.append(f); learned += 1
            except Exception:
                continue
        return learned

    def reset(self, name: str):
        self._history.pop(name, None)

    # --- Mode Her: route a spoken/typed message to CONVERSATION (local chat) or WORK (agent) ---
    def route(self, message: str) -> str:
        """Conversation-first: Ember talks locally; hand off to the DeepSeek work-agent for real
        computer actions AND for composing original text (the tiny local model writes it poorly)."""
        m = (message or "").strip()
        if not m:
            return "chat"
        # Deterministic high-precision shortcuts (reliable across EN/FR — the 1.5B classifier is not):
        #   compose original text, a clear file/app/media action, "open <app>", or a leading
        #   imperative verb → the agent. (Conversation-first only for greetings/questions/feelings.)
        if (_CREATE_RE.search(m) or _ACTION_RE.search(m) or _LAUNCH_RE.search(m)
                or _IMPERATIVE_RE.search(m)):
            return "task"
        sys = ("Classify the user's message to a personal on-device AI as TASK or CHAT.\n"
               "TASK = the user wants Ember to DO, MAKE or WRITE something: handle files or apps, "
               "search memory, summarize — or compose any original text (note, message, email, poem, "
               "story, song, list, plan, code).\n"
               "CHAT = pure conversation: greetings, small talk, questions about facts / the world / "
               "themselves, opinions, feelings.\n"
               "Examples:\n"
               "write me a poem about the sea => TASK\n"
               "écris-moi un message d'anniversaire pour Léa => TASK\n"
               "rédige un email pour mon patron => TASK\n"
               "list the files on my desktop => TASK\n"
               "summarize this PDF => TASK\n"
               "how are you today? => CHAT\n"
               "what is the capital of Italy? => CHAT\n"
               "I feel a bit tired => CHAT\n"
               "Answer with ONE word: TASK or CHAT.")
        try:
            with self._lock:
                out = self.mlx.chat([{"role": "system", "content": sys},
                                     {"role": "user", "content": m}],
                                    max_tokens=4, temperature=0.0)   # greedy → routing is deterministic
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
                return self._send(200, [{"id": f.id, "kind": f.kind, "text": f.text,
                                         "source": f.source, "created_at": f.created_at} for f in facts])
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
                if u.path == "/generate":
                    # Plus-value : générer un VRAI élément (document) en local, ancré mémoire/persona.
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    name = b["name"]; brief = (b.get("prompt") or b.get("brief") or "").strip()
                    if not (MODELS_DIR / name).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    if not brief:
                        return self._send(400, {"error": "décris ce que tu veux générer"})
                    return self._send(200, engine.generate(name, brief))
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
                    learned = engine.ingest(b["name"], b.get("text") or "", b.get("source") or "file")
                    return self._send(200, {"ok": True, "learned": learned})
                if u.path == "/forget_source":
                    # CRUD « delete » sur l'apprentissage : oublier tous les faits appris depuis une
                    # source (chemin de fichier/dossier), par préfixe. 100% local.
                    name = b["name"]; prefix = (b.get("prefix") or "").strip()
                    if not (MODELS_DIR / name).exists() or not prefix:
                        return self._send(200, {"ok": True, "removed": 0})
                    removed = store_for_model(name).delete_by_source(prefix)
                    return self._send(200, {"ok": True, "removed": removed})
                if u.path == "/ingest_notes":
                    # REAL Apple Notes connector (§4.A) — read the user's notes via AppleScript,
                    # then run the same ingestion pipeline (text → facts). 100% local.
                    if not engine.ready:
                        return self._send(503, {"error": "model loading"})
                    if not (MODELS_DIR / b["name"]).exists():
                        return self._send(404, {"error": "IA introuvable"})
                    from aneforge.agent import notes_corpus
                    corpus, used, total = notes_corpus()
                    if not corpus:
                        return self._send(200, {"ok": True, "learned": 0, "notes": 0, "total": total,
                                                "error": "Aucune note lisible — autorise l'accès à Notes."})
                    learned = engine.ingest(b["name"], corpus, source="notes:apple")
                    return self._send(200, {"ok": True, "learned": learned, "notes": used, "total": total})
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
                    sess.cloud_consented = bool(b.get("cloud_ok"))   # cloud déjà accordé cette session
                    sess.blocked = set(b.get("blocked") or [])   # périmètres OFF dans Réglages → refusés
                    _AGENT_SESSIONS[sid] = sess
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    self.wfile.write((json.dumps({"type": "session", "id": sid}) + "\n").encode())
                    self.wfile.flush()

                    def _worker():
                        try:
                            run_agent(name, task, sess.emit, sess.ask_permission,
                                      should_stop=sess.stopped)
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
                if u.path == "/agent_stop":
                    # « Stop » → arrête le worker côté serveur : plus aucun outil exécuté après ça.
                    sess = _AGENT_SESSIONS.get(b.get("session"))
                    if sess:
                        sess.stop()
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
                    f = store_for_model(name).add(text, kind=(b.get("kind") or classify_kind(text)),
                                                  source="explicit")
                    return self._send(200, {"ok": True, "added": bool(f), "id": (f.id if f else None)})
                if u.path == "/search":
                    # Mémoire search box — hybrid keyword + multilingual-semantic ranking.
                    name = b["name"]; q = b.get("q") or b.get("query") or ""
                    if not (MODELS_DIR / name).exists():
                        return self._send(200, [])
                    facts = store_for_model(name).search(q)
                    return self._send(200, [{"id": f.id, "kind": f.kind, "text": f.text,
                                             "source": f.source, "created_at": f.created_at} for f in facts])
                if u.path == "/forget":
                    s = store_for_model(b["name"])
                    removed = s.clear() if b.get("all") else (1 if s.delete(int(b["id"])) else 0)
                    return self._send(200, {"ok": True, "removed": removed})
                if u.path == "/reset":
                    engine.reset(b["name"]); return self._send(200, {"ok": True})
                if u.path == "/settings":
                    _save_settings(b["name"], b.get("persona", ""), int(b.get("max_tokens", 220)),
                                   float(b.get("temperature", 0.7)), b.get("tone", "Calm"))
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
                        try:
                            os.chmod(p, 0o600)              # §7 : secret lisible par le seul propriétaire
                            os.chmod(p.parent, 0o700)
                        except Exception:
                            pass
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
