"""Drum transcription: onset detection plus hit classification, never pitch tracking.

fast      Three band-limited onset detectors (sub / mid / high) mapped to
          kick, snare and closed hi-hat. No model.
balanced  Broadband onset detection, then a trained multi-label classifier
          (one logistic regression per drum class over the hit's spectrum and
          decay; kstem/models/drum_classifier.npz, trained by
          eval/train_drums.py on kits the accuracy fixtures do not use).
high      balanced, plus extra onset candidates from the sub and high bands
          (hits masked by a louder simultaneous hit) and sample-level onset
          refinement.

Output notes carry a drum class; MIDI note numbers come from the drum map
(General MIDI by default, configurable in the app).
"""
from __future__ import annotations

from collections import Counter
from functools import lru_cache
from pathlib import Path

import librosa
import numpy as np
from scipy.signal import find_peaks

from . import post
from .notes import Note

GM_MAP = {
    "kick": 36, "rim": 37, "snare": 38, "clap": 39, "closed_hat": 42, "low_tom": 45, "open_hat": 46,
    "high_tom": 50, "crash": 49, "ride": 51, "perc": 56,
}
CLASSES = list(GM_MAP)

N_FFT = 2048
HOP = 256


def _spec(y, sr):
    S = np.abs(librosa.stft(y, n_fft=N_FFT, hop_length=HOP))
    return S, librosa.fft_frequencies(sr=sr, n_fft=N_FFT)


def _pick(env: np.ndarray, fps: float, sensitivity: float, min_gap: float = 0.03) -> tuple[np.ndarray, np.ndarray]:
    """Peak-pick an onset envelope with an adaptive (moving median) threshold."""
    if env.max() <= 0:
        return np.array([], dtype=int), np.array([])
    env = env / env.max()
    w = int(0.4 * fps)
    from scipy.ndimage import median_filter

    local = median_filter(env, size=max(3, w))
    floor = 0.06 + 0.22 * (1 - sensitivity)
    thresh = local + floor
    peaks, props = find_peaks(env, height=thresh, distance=max(1, int(min_gap * fps)))
    return peaks, env[peaks]


def _band_energy(S, freqs, lo, hi):
    m = (freqs >= lo) & (freqs < hi)
    return S[m].sum(axis=0) if m.any() else np.zeros(S.shape[1])


LEARNED_CLASSES = ["kick", "snare", "clap", "rim", "closed_hat", "open_hat", "low_tom", "high_tom", "crash", "ride"]
FEATURE_VERSION = 1
N_MELS = 40
# Frames after the onset whose spectra form the feature (hop 256 at 44.1 kHz = 5.8 ms).
OFFSETS = (0, 1, 2, 4, 8, 16, 32)
MODEL_PATH = Path(__file__).parent / "models" / "drum_classifier.npz"


# Classes that rarely sound together on one onset: the weaker is dropped unless it is itself very likely.
EXCLUSIVE = [("snare", "clap", "rim"), ("closed_hat", "open_hat"), ("low_tom", "high_tom"), ("crash", "ride")]
# Extra (band-only) onsets may only produce these classes.
BAND_CLASSES = {"sub": {"kick"}, "high": {"closed_hat", "open_hat", "crash", "ride"}}


def detect_onsets(y: np.ndarray, sr: int, sensitivity: float = 0.5, extra_bands: bool = False,
                  with_source: bool = False):
    """Onset times (s). With extra_bands, also onsets seen only in the sub or high band
    (returned with their band name when with_source is set)."""
    M = librosa.power_to_db(librosa.feature.melspectrogram(y=y, sr=sr, n_fft=N_FFT, hop_length=HOP, n_mels=96))
    env = librosa.onset.onset_strength(S=M, sr=sr, hop_length=HOP, lag=2, max_size=3)
    delta = 0.02 + 0.12 * (1 - sensitivity)
    frames = librosa.onset.onset_detect(onset_envelope=env, sr=sr, hop_length=HOP, delta=delta, wait=3, backtrack=False)
    found = [(float(t), "full") for t in librosa.frames_to_time(frames, sr=sr, hop_length=HOP)]
    if extra_bands:
        S, freqs = _spec(y, sr)
        for name, (lo, hi) in (("sub", (30, 100)), ("high", (7000, 18000))):
            e = np.maximum(np.diff(np.log1p(1000 * _band_energy(S, freqs, lo, hi) / (S.max() + 1e-9)), prepend=0), 0)
            peaks, _ = _pick(e, sr / HOP, min(sensitivity, 0.4))
            for t in peaks * HOP / sr:
                if np.min(np.abs(np.array([f[0] for f in found]) - t)) > 0.03:
                    found.append((float(t), name))
    found.sort()
    # Onset frames are centred; move each to the sample-level start of its attack.
    env_f, step = post.amplitude_envelope(y, sr, hop=16)
    times = np.array([post.refine_onset(env_f, step, t, before=0.025, after=0.015) for t, _ in found])
    if with_source:
        return times, [src for _, src in found]
    return times


def hit_features(y: np.ndarray, sr: int, onsets: np.ndarray) -> np.ndarray:
    """Gain-independent spectral shape and decay of each hit, plus its relative level."""
    M = librosa.power_to_db(librosa.feature.melspectrogram(y=y, sr=sr, n_fft=N_FFT, hop_length=HOP, n_mels=N_MELS,
                                                           fmin=25, fmax=18000), ref=np.max)
    n = M.shape[1]
    feats = []
    peaks = []
    for t in onsets:
        i = int(round(t * sr / HOP))
        frames = [M[:, min(n - 1, max(0, i + o))] for o in OFFSETS]
        pre = M[:, max(0, i - 3)]
        stack = np.stack(frames)
        top = float(stack[:3].max())
        peaks.append(top)
        feats.append(np.concatenate([(stack - top).ravel(), np.clip(stack[1] - pre, -10, 60), [0.0]]))
    feats = np.array(feats, dtype=np.float32) if feats else np.zeros((0, N_MELS * len(OFFSETS) + N_MELS + 1), np.float32)
    if len(peaks):
        ref = np.percentile(peaks, 95)
        feats[:, -1] = np.array(peaks) - ref
    return feats


@lru_cache(maxsize=1)
def _model():
    z = np.load(MODEL_PATH)
    if int(z["feature_version"]) != FEATURE_VERSION:
        raise RuntimeError("drum_classifier.npz was trained on a different feature version; run eval/train_drums.py")
    return z["W"], z["b"], z["mu"], z["sd"], [str(c) for c in z["classes"]]


def classify_hits(feats: np.ndarray) -> tuple[np.ndarray, list[str]]:
    W, b, mu, sd, classes = _model()
    z = ((feats - mu) / sd) @ W + b
    return 1 / (1 + np.exp(-z)), classes


def transcribe(y: np.ndarray, sr: int, mode: str = "balanced", sensitivity: float = 0.5,
               progress=None) -> tuple[list[Note], list[str]]:
    fps = sr / HOP
    removed: Counter = Counter()
    events: list[tuple[float, str, float, float]] = []  # (time, class, level, confidence)
    if progress:
        progress(0.1, "Detecting drum hits")
    if mode == "fast":
        S, freqs = _spec(y, sr)
        bands = {"kick": (30, 120), "snare": (150, 3000), "closed_hat": (7000, 20000)}
        for cls, (lo, hi) in bands.items():
            env = np.maximum(np.diff(np.log1p(100 * _band_energy(S, freqs, lo, hi)), prepend=0), 0)
            peaks, h = _pick(env, fps, sensitivity)
            events += [(p / fps - HOP / sr / 2, cls, float(v), float(v)) for p, v in zip(peaks, h)]
    else:
        onsets, sources = detect_onsets(y, sr, sensitivity, extra_bands=(mode == "high"), with_source=True)
        if progress:
            progress(0.5, "Classifying hits")
        feats = hit_features(y, sr, onsets)
        if len(onsets):
            probs, classes = classify_hits(feats)
            threshold = 0.5 + 0.2 * (0.5 - sensitivity)
            level = feats[:, -1]
            for k, t in enumerate(onsets):
                fired = [(classes[c], probs[k, c]) for c in range(len(classes)) if probs[k, c] >= threshold]
                if sources[k] != "full":
                    fired = [(c, p) for c, p in fired if c in BAND_CLASSES[sources[k]] and p >= 0.7]
                for group in EXCLUSIVE:
                    g = sorted([f for f in fired if f[0] in group], key=lambda f: -f[1])
                    for weaker in g[1:]:
                        if weaker[1] < 0.85:
                            fired.remove(weaker)
                            removed["exclusive"] += 1
                if not fired:
                    removed["unclassified onsets"] += 1
                for cls, p in fired:
                    events.append((float(t), cls, float(level[k]), float(p)))
    notes: list[Note] = []
    if events:
        if mode == "fast":
            top = {}
            for _, c, s, _ in events:
                top[c] = max(top.get(c, 0.0), s)
            vel = lambda c, s: 30 + 97 * (s / (top[c] + 1e-12)) ** 0.5
        else:
            vel = lambda c, s: 127 * 10 ** (np.clip(s, -40, 0) / 40)  # level re. loud hits, -40..0 dB
        for t, c, s, conf in events:
            notes.append(Note(pitch=GM_MAP[c], start=max(0.0, t), end=max(0.0, t) + 0.1,
                              velocity=int(np.clip(round(vel(c, s)), 1, 127)), confidence=float(np.clip(conf, 0, 1)), drum=c))
    # Within 25 ms a class keeps only its strongest hit.
    notes.sort(key=lambda n: (n.drum, n.start))
    dedup: list[Note] = []
    for n in notes:
        if dedup and dedup[-1].drum == n.drum and n.start - dedup[-1].start < 0.025:
            if n.velocity > dedup[-1].velocity:
                dedup[-1] = n
            removed["duplicates"] += 1
            continue
        dedup.append(n)
    return sorted(dedup, key=lambda n: (n.start, n.pitch)), post.summarize(removed)
