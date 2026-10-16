"""Proposes an instrument class for a stem from measured audio features.

The proposal picks the transcription pipeline; the user can always override
it. Each proposal carries the features it was based on so the UI can show
why, and a confidence that is a heuristic margin, not a probability.
"""
from __future__ import annotations

from dataclasses import dataclass

import librosa
import numpy as np

CLASSES = [
    "drums", "bass_guitar", "synth_bass", "mono_synth", "poly_synth", "piano", "guitar", "vocal", "other_melodic",
]
LABELS = {
    "drums": "Drums / percussion", "bass_guitar": "Bass guitar", "synth_bass": "Synth bass",
    "mono_synth": "Monophonic synth", "poly_synth": "Polyphonic synth", "piano": "Piano / keys",
    "guitar": "Guitar", "vocal": "Vocal melody", "other_melodic": "Other melodic",
}
# Which transcription pipeline each class uses.
PIPELINE = {
    "drums": "drums", "bass_guitar": "mono", "synth_bass": "mono", "mono_synth": "mono", "vocal": "mono",
    "poly_synth": "poly", "piano": "poly", "guitar": "poly", "other_melodic": "mono",
}
# pYIN search ranges per class (Hz).
F0_RANGE = {
    "bass_guitar": (30.0, 400.0), "synth_bass": (27.5, 500.0), "mono_synth": (50.0, 2100.0),
    "vocal": (65.0, 1100.0), "other_melodic": (50.0, 2100.0),
}


@dataclass
class Classification:
    proposed: str
    confidence: float
    scores: dict[str, float]
    features: dict[str, float]

    def to_json(self) -> dict:
        return {
            "proposed": self.proposed,
            "label": LABELS[self.proposed],
            "confidence": round(self.confidence, 3),
            "scores": {k: round(v, 3) for k, v in sorted(self.scores.items(), key=lambda kv: -kv[1])},
            # The same scores as [class, score] pairs, best first (dictionary keys get renamed by some JSON decoders).
            "ranked": [[k, round(v, 3)] for k, v in sorted(self.scores.items(), key=lambda kv: -kv[1])],
            "features": {k: round(v, 4) for k, v in self.features.items()},
        }


def _busiest_excerpt(y: np.ndarray, sr: int, seconds: float) -> np.ndarray:
    n = int(seconds * sr)
    if len(y) <= n:
        return y
    hop = sr // 2
    rms = librosa.feature.rms(y=y, frame_length=hop, hop_length=hop)[0]
    win = int(seconds * 2)
    sums = np.convolve(rms, np.ones(win), mode="valid")
    start = int(np.argmax(sums)) * hop
    return y[start:start + n]


def features(y: np.ndarray, sr: int, polyphony: float | None = None, median_pitch: float | None = None) -> dict[str, float]:
    ex = _busiest_excerpt(y, sr, 12.0)
    H, P = librosa.effects.hpss(ex)
    perc = float(np.sum(P ** 2) / (np.sum(H ** 2) + np.sum(P ** 2) + 1e-12))
    y11 = librosa.resample(ex, orig_sr=sr, target_sr=11025)
    f0, vflag, _ = librosa.pyin(y11, fmin=30, fmax=2000, sr=11025, frame_length=1024, hop_length=256)
    rms = librosa.feature.rms(y=y11, frame_length=1024, hop_length=256)[0][: len(f0)]
    active = rms > max(1e-4, 0.05 * float(np.max(rms)))
    voiced = float(np.mean(vflag[active])) if active.any() else 0.0
    f0v = f0[vflag & active]
    median_f0 = float(np.median(f0v)) if f0v.size else 0.0
    # Vibrato / glide: cents deviation from a 150 ms median of the pitch track.
    wobble = 0.0
    if f0v.size > 20:
        cents = 1200 * np.log2(f0v / np.median(f0v))
        smooth = np.convolve(cents, np.ones(7) / 7, mode="same")
        from scipy.ndimage import median_filter

        wobble = float(np.std(smooth - median_filter(smooth, size=13)))
    S = np.abs(librosa.stft(ex, n_fft=2048, hop_length=512))
    act = librosa.feature.rms(S=S)[0] > 0.05 * float(np.max(librosa.feature.rms(S=S)[0]) + 1e-12)
    centroid = float(np.median(librosa.feature.spectral_centroid(S=S, sr=sr)[0][act])) if act.any() else 0.0
    flatness = float(np.median(librosa.feature.spectral_flatness(S=S)[0][act])) if act.any() else 0.0
    out = {
        "percussive_ratio": perc, "voiced_fraction": voiced, "median_f0_hz": median_f0,
        "pitch_wobble_cents": wobble, "spectral_centroid_hz": centroid, "spectral_flatness": flatness,
    }
    if polyphony is not None:
        out["polyphony"] = float(polyphony)
    if median_pitch is not None:
        out["median_note"] = float(median_pitch)
    return out


def note_features(y: np.ndarray, sr: int) -> tuple[float | None, float | None]:
    """Polyphony (after overtone filtering) and median MIDI note from Basic Pitch on a 20 s excerpt."""
    from . import poly, post

    ex = _busiest_excerpt(y, sr, 20.0)
    notes = poly.decode(poly.model_output(ex, sr), "fast")
    post.suppress_harmonics(notes, 0.55)
    if not notes:
        return 0.0, None
    return polyphony_from_notes(notes, len(ex) / sr), float(np.median([n.pitch for n in notes]))


def polyphony_from_notes(notes, duration: float) -> float:
    """Mean number of simultaneously sounding notes over the time any note sounds."""
    if not notes:
        return 0.0
    grid = np.arange(0, duration, 0.02)
    count = np.zeros_like(grid)
    for n in notes:
        count[(grid >= n.start) & (grid < n.end)] += 1
    on = count > 0
    return float(np.mean(count[on])) if on.any() else 0.0


def classify(feat: dict[str, float]) -> Classification:
    s = {c: 0.0 for c in CLASSES}
    perc, voiced, f0 = feat["percussive_ratio"], feat["voiced_fraction"], feat["median_f0_hz"]
    cent, poly, wobble = feat["spectral_centroid_hz"], feat.get("polyphony", 1.0), feat["pitch_wobble_cents"]
    s["drums"] = perc * 1.2 + (1 - voiced) * 0.8 - 0.6
    pitched = voiced * (1.2 - perc)
    if "median_note" in feat:
        m = feat["median_note"]
        is_low = 1.0 if m < 50 else (0.4 if m < 53 else 0.0)
    else:
        is_low = 1.0 if 0 < f0 < 140 else (0.4 if f0 < 200 else 0.0)
    brightness = cent / max(f0, 20.0)
    s["synth_bass"] = pitched * is_low * (0.6 + 0.4 * np.tanh((brightness - 7) / 3))
    s["bass_guitar"] = pitched * is_low * (0.6 - 0.4 * np.tanh((brightness - 7) / 3))
    upper = pitched * (1 - is_low)
    polyness = float(np.clip((poly - 1.35) / 0.6, 0, 1))
    bright = float(np.clip((cent - 1200) / 1500, 0, 1))
    s["poly_synth"] = upper * polyness * (0.5 + 0.5 * bright) + 0.1 * polyness
    s["piano"] = upper * polyness * (1.0 - 0.6 * bright) + 0.1 * polyness
    s["guitar"] = upper * polyness * 0.4
    mono = upper * (1 - polyness)
    vib = float(np.clip((wobble - 12) / 20, 0, 1))
    s["vocal"] = mono * vib
    s["mono_synth"] = mono * (1 - vib) * (0.4 + 0.6 * bright)
    s["other_melodic"] = mono * (1 - vib) * (1.0 - 0.6 * bright)
    ranked = sorted(s.items(), key=lambda kv: -kv[1])
    top, second = ranked[0], ranked[1]
    conf = float(np.clip((top[1] - second[1]) / (abs(top[1]) + 1e-6), 0, 1))
    return Classification(top[0], conf, s, feat)
