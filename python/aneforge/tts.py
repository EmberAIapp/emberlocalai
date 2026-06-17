"""Local neural voice for Ember (Mode Her) — Kokoro-82M via MLX (mlx-audio).

100% local, no cloud (honesty §2.4). Multilingual: Ember speaks the SYSTEM language.
Grapheme→phoneme uses a BUNDLED espeak-ng (via espeakng_loader), so it works on any Mac
with no Homebrew install — the same one local engine that powers chat now also gives Ember
a natural voice, instead of the robotic Apple compact voices.

Design:
- ONE Kokoro model loaded once (lazy, like the chat model), reused across requests.
- We drive KokoroPipeline directly and swap its g2p to EspeakG2P(language=…) per request,
  which covers fr/en/es/pt/it/de WITHOUT needing spaCy (misaki.en) or torch/onnxruntime
  (no Python-3.14 wheels for those).
- mlx-audio 0.4.4's iSTFTNet vocoder has an off-by-a-few-samples bug (its _f02sine
  down/up interpolation rounds the length differently from _f02uv) → certain inputs raised
  `[broadcast_shapes]`. We monkeypatch SineGen.__call__ to align the lengths. Kept HERE (not
  by editing the vendored file) so it survives re-embedding the venv into the .app.
- Emojis and markdown symbols are stripped before speaking (they were read aloud literally).
- Long replies are chunked by sentence (the lib itself recommends this) and concatenated.
"""

from __future__ import annotations

import io
import os
import re
import threading

import numpy as np

SR = 24000
KOKORO_REPO = os.environ.get("EMBER_KOKORO_REPO", "prince-canuma/Kokoro-82M")

# system language (2-letter) → (espeak language, Kokoro voice pack)
_LANG = {
    "fr": ("fr-fr", "ff_siwis"),
    "en": ("en-us", "af_heart"),
    "es": ("es", "ef_dora"),
    "pt": ("pt", "pf_dora"),
    "it": ("it", "if_sara"),
    "de": ("de", "af_heart"),   # Kokoro has no German voice; espeak-de + a neutral timbre
}
_DEFAULT = ("en-us", "af_heart")

_LOCK = threading.Lock()
_PIPE = None
_G2P = {}          # espeak-language → EspeakG2P (built once each)
_READY = False

# Emojis + pictographs + dingbats + arrows that TTS would otherwise read out loud.
_EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "←-⇿⌀-⏿⬀-⯿️‍]+"
)


def available() -> bool:
    """True if the neural-voice stack is importable (else the app uses the OS voice)."""
    try:
        import espeakng_loader  # noqa: F401
        import mlx_audio  # noqa: F401
        from misaki.espeak import EspeakG2P  # noqa: F401
        return True
    except Exception:
        return False


def _configure_espeak():
    import espeakng_loader
    os.environ.setdefault("PHONEMIZER_ESPEAK_LIBRARY", espeakng_loader.get_library_path())
    os.environ.setdefault("ESPEAK_DATA_PATH", espeakng_loader.get_data_path())
    try:
        from phonemizer.backend.espeak.wrapper import EspeakWrapper
        EspeakWrapper.set_library(espeakng_loader.get_library_path())
    except Exception:
        pass


def _patch_vocoder():
    """Align _f02sine's length to _f02uv's (the true f0 length) so the harmonic-source
    ops broadcast. Fixes mlx-audio 0.4.4's `[broadcast_shapes]` crash on many inputs."""
    import mlx.core as mx
    from mlx_audio.tts.models.kokoro import istftnet as I

    def _sine_gen_call(self, f0):
        fn = f0 * mx.arange(1, self.harmonic_num + 2)[None, None, :]
        sine = self._f02sine(fn) * self.sine_amp
        uv = self._f02uv(f0)
        L = uv.shape[1]
        if sine.shape[1] > L:
            sine = sine[:, :L, :]
        elif sine.shape[1] < L:
            sine = mx.pad(sine, ((0, 0), (0, L - sine.shape[1]), (0, 0)))
        noise_amp = uv * self.noise_std + (1 - uv) * self.sine_amp / 3
        sine = sine * uv + noise_amp * mx.random.normal(sine.shape)
        return sine, uv, noise_amp * mx.random.normal(uv.shape)

    I.SineGen.__call__ = _sine_gen_call


def warmup():
    """Load Kokoro once. Safe to call repeatedly; first call does the work."""
    global _PIPE, _READY
    if _READY:
        return
    with _LOCK:
        if _READY:
            return
        _configure_espeak()
        _patch_vocoder()
        from mlx_audio.tts.models.kokoro.pipeline import KokoroPipeline
        from mlx_audio.tts.utils import load_model
        model = load_model(KOKORO_REPO)
        # lang_code 'f' just initialises an espeak-based pipeline; we swap g2p per request.
        _PIPE = KokoroPipeline(lang_code="f", model=model, repo_id=KOKORO_REPO)
        _READY = True


def _clean(text: str) -> str:
    t = _EMOJI.sub("", text or "")
    t = re.sub(r"[*_`#>|~]", "", t)          # markdown symbols read aloud otherwise
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _sentences(text: str):
    parts = re.split(r"(?<=[.!?…])\s+|\n+", text)
    return [p.strip() for p in parts if p.strip()]


def synth(text: str, lang: str = "fr"):
    """Synthesize speech. Returns (float32 mono @24k np.array, SR) or (None, SR) if empty."""
    text = _clean(text)
    if not text:
        return None, SR
    warmup()
    esp, voice = _LANG.get((lang or "fr")[:2].lower(), _DEFAULT)
    from misaki.espeak import EspeakG2P
    chunks = []
    with _LOCK:  # MLX model + pipeline state are not thread-safe; serialize
        g = _G2P.get(esp)
        if g is None:
            g = EspeakG2P(language=esp)
            _G2P[esp] = g
        _PIPE.g2p = g
        for sentence in _sentences(text):
            for result in _PIPE(sentence, voice=voice, speed=1.0):
                audio = result[2]
                if audio is not None:
                    chunks.append(np.asarray(audio).reshape(-1))
    if not chunks:
        return None, SR
    return np.concatenate(chunks), SR


def synth_wav_bytes(text: str, lang: str = "fr"):
    """Synthesize → 16-bit PCM WAV bytes (or None if there's nothing to say)."""
    audio, sr = synth(text, lang)
    if audio is None:
        return None
    import soundfile as sf
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()
