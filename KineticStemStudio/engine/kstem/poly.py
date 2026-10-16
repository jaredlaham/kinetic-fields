"""Polyphonic transcription: Spotify Basic Pitch (Apache-2.0) via ONNX Runtime.

Basic Pitch's network is used as published; what changes between modes is
the decoding thresholds and our post-processing (see MODES).
"""
from __future__ import annotations

import contextlib
import io
import logging
import os
import tempfile
from collections import Counter
from pathlib import Path

import numpy as np
import soundfile as sf

from . import post
from .notes import Note

_MODEL = None

# Decoding settings per quality mode. Fast is Basic Pitch's own defaults with
# no post-processing. Values for balanced/high were chosen on the fixture set
# in eval/ (docs/ACCURACY.md): with only two polyphonic fixtures they are a
# starting point, not a tuned optimum.
MODES = {
    "fast": dict(onset=0.5, frame=0.3, min_ms=127.7, melodia=True, post=False, hpss=False, harmonic_ratio=0.0),
    "balanced": dict(onset=0.55, frame=0.3, min_ms=80.0, melodia=True, post=True, hpss=False, harmonic_ratio=0.55),
    "high": dict(onset=0.55, frame=0.3, min_ms=80.0, melodia=True, post=True, hpss=False, harmonic_ratio=0.55,
                 rescue_onset=0.3, rescue_rise_db=9.0),
    # One-voice decoding used by the monophonic pipeline.
    "mono": dict(onset=0.6, frame=0.3, min_ms=58.0, melodia=True, post=False, hpss=False, harmonic_ratio=0.9),
}


def available() -> tuple[bool, str]:
    try:
        _model()
        return True, "Basic Pitch ICASSP 2022 (ONNX)"
    except Exception as e:  # pragma: no cover - reported to the user by `doctor`
        return False, f"Basic Pitch unavailable: {e}"


def _quiet_import():
    logging.getLogger().setLevel(logging.ERROR)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from basic_pitch import ICASSP_2022_MODEL_PATH, inference, note_creation
    return ICASSP_2022_MODEL_PATH, inference, note_creation


def _model():
    global _MODEL
    if _MODEL is None:
        path, inference, _ = _quiet_import()
        onnx = Path(path).with_suffix(".onnx") if Path(path).suffix != ".onnx" else Path(path)
        _MODEL = inference.Model(str(onnx if onnx.exists() else path))
    return _MODEL


def release() -> None:
    """Free the model's memory (it is reloaded on next use)."""
    global _MODEL
    _MODEL = None


def model_output(y: np.ndarray, sr: int) -> dict:
    _, inference, _ = _quiet_import()
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "in.wav")
        sf.write(wav, y, sr, subtype="FLOAT")
        with contextlib.redirect_stdout(io.StringIO()):
            return inference.run_inference(wav, _model())


def decode(output: dict, mode: str, fmin: float | None = None, fmax: float | None = None) -> list[Note]:
    _, _, note_creation = _quiet_import()
    cfg = MODES[mode]
    from basic_pitch.constants import AUDIO_SAMPLE_RATE, FFT_HOP

    min_len = int(round(cfg["min_ms"] / 1000 * (AUDIO_SAMPLE_RATE / FFT_HOP)))
    with contextlib.redirect_stdout(io.StringIO()):
        _, events = note_creation.model_output_to_notes(
            output, onset_thresh=cfg["onset"], frame_thresh=cfg["frame"], min_note_len=min_len,
            min_freq=fmin, max_freq=fmax, include_pitch_bends=True, multiple_pitch_bends=False,
            melodia_trick=cfg["melodia"],
        )
    notes = []
    for start, end, pitch, amp, bends in events:
        amp = float(np.clip(amp, 0, 1))
        n = Note(pitch=int(pitch), start=float(start), end=float(end), velocity=int(np.clip(round(amp * 127), 1, 127)),
                 confidence=amp)
        notes.append(n)
    notes.sort(key=lambda n: (n.start, n.pitch))
    return notes


def transcribe(y: np.ndarray, sr: int, mode: str = "balanced", fmin: float | None = None,
               fmax: float | None = None, progress=None) -> tuple[list[Note], list[str]]:
    cfg = MODES[mode]
    src = y
    if cfg["hpss"]:
        # Harmonic part only: drum bleed and pick/hammer noise stop producing notes.
        import librosa

        if progress:
            progress(0.05, "Separating harmonic content")
        src = librosa.effects.harmonic(y, margin=2.0)
    if progress:
        progress(0.15, "Running Basic Pitch")
    out = model_output(src, sr)
    if progress:
        progress(0.7, "Decoding notes")
    notes = decode(out, mode, fmin, fmax)
    removed: Counter = Counter()
    rise = post.pitch_rise_db(y, sr) if cfg["post"] else None
    if cfg.get("rescue_onset"):
        # Second decode at a lower onset threshold: a weak candidate is kept only
        # if its own pitch band shows a clear attack and nothing already covers it.
        MODES["_rescue"] = {**cfg, "onset": cfg["rescue_onset"]}
        extra = decode(out, "_rescue", fmin, fmax)
        for n in extra:
            if any(m.pitch == n.pitch and abs(m.start - n.start) < 0.06 for m in notes):
                continue
            if any(m.pitch == n.pitch and m.start < n.start < m.end for m in notes):
                continue
            if rise(n.pitch, n.start) >= cfg["rescue_rise_db"]:
                notes.append(n)
                removed["rescued"] += 1
        notes.sort(key=lambda n: (n.start, n.pitch))
    if cfg["post"]:
        if progress:
            progress(0.8, "Removing overtones and split notes, refining onsets")
        removed["harmonics"] += post.suppress_harmonics(notes, cfg["harmonic_ratio"])
        removed["retriggers"] += post.merge_false_retriggers(notes, rise, 6.0)
        post.refine_onsets(notes, y, sr)
    return notes, post.summarize(removed)
