"""Tempo, beat grid and downbeat estimation.

The estimate is a suggestion: the app always lets the user override BPM,
meter and grid offset, and shows the half/double-time alternatives.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import librosa
import numpy as np

SR = 22050
HOP = 256


@dataclass
class TempoResult:
    bpm: float
    confidence: float  # 0..1: how much the winning tempo stands out
    alternatives: list[float]  # half / double time candidates
    beats: list[float]  # seconds
    downbeat: float  # seconds of the first bar line
    downbeat_confidence: float
    beats_per_bar: int
    tempo_stable: bool
    local_bpm_range: tuple[float, float]
    warnings: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        return {
            "bpm": round(self.bpm, 2),
            "confidence": round(self.confidence, 3),
            "alternatives": [round(b, 2) for b in self.alternatives],
            "beats": [round(b, 4) for b in self.beats],
            "downbeat": round(self.downbeat, 4),
            "downbeat_confidence": round(self.downbeat_confidence, 3),
            "beats_per_bar": self.beats_per_bar,
            "tempo_stable": self.tempo_stable,
            "local_bpm_range": [round(x, 2) for x in self.local_bpm_range],
            "warnings": self.warnings,
        }


def onset_envelopes(y: np.ndarray, sr: int = SR) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Full-band, low-band (<150 Hz) and mid-band (150 Hz-2 kHz) onset strength at one frame rate."""
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    db = librosa.amplitude_to_db(S, ref=np.max)
    full = librosa.onset.onset_strength(S=db, sr=sr, hop_length=HOP, lag=1, max_size=1)
    low = librosa.onset.onset_strength(S=db[freqs < 150], sr=sr, hop_length=HOP, lag=1, max_size=1)
    mid = librosa.onset.onset_strength(S=db[(freqs >= 150) & (freqs < 2000)], sr=sr, hop_length=HOP, lag=1, max_size=1)
    n = min(len(full), len(low), len(mid))
    return full[:n], low[:n], mid[:n]


def _norm(x: np.ndarray) -> np.ndarray:
    x = x - np.min(x)
    m = np.max(x)
    return x / m if m > 0 else x


def _interp(a: np.ndarray, i: float) -> float:
    if i < 0 or i >= len(a) - 1:
        return 0.0
    j = int(i)
    f = i - j
    return float(a[j] * (1 - f) + a[j + 1] * f)


def _comb_score(ac: np.ndarray, period: float) -> float:
    """Support for a beat period (in frames): the beat, bar, and 8th/16th subdivisions."""
    return (_interp(ac, period) + 0.5 * _interp(ac, 2 * period) + 0.35 * _interp(ac, 4 * period)
            + 0.4 * _interp(ac, period / 2) + 0.2 * _interp(ac, period / 4))


def _grid_fit(env: np.ndarray, period: float) -> tuple[float, float]:
    """Best phase (frames) of a fixed grid and its mean envelope value."""
    best = (0.0, -1.0)
    for phase in np.arange(0, period, 0.25):
        idx = np.arange(phase, len(env) - 1, period)
        v = np.mean([_interp(env, i) for i in idx]) if len(idx) else 0.0
        if v > best[1]:
            best = (float(phase), float(v))
    return best


def refine_phase(beats: list[float], signals: list[tuple[np.ndarray, int]]) -> tuple[list[float], float]:
    """Shift the whole grid so beats line up with where attacks start, not where flux peaks.

    Uses only beats that have a clear attack nearby; returns (beats, shift_seconds).
    """
    from .post import amplitude_envelope, refine_onset

    shifts = []
    for y, sr in signals:
        env, step = amplitude_envelope(y, sr)
        for b in beats:
            a, e = int((b - 0.05) / step), int((b + 0.03) / step)
            if a < 1 or e >= len(env):
                continue
            rise = float(np.max(np.diff(env[a:e])))
            if rise <= 0.05 * float(np.max(env)):
                continue
            shifts.append(refine_onset(env, step, b, 0.05, 0.03) - b)
    if len(shifts) < 4:
        return beats, 0.0
    shift = float(np.median(shifts))
    return [b + shift for b in beats], shift


def estimate(envs: list[tuple[np.ndarray, np.ndarray, np.ndarray]], sr: int = SR, prior_bpm: float = 120.0,
             beats_per_bar: int = 4) -> TempoResult:
    """Estimate one shared grid from one or more stems' onset envelopes (normalised and summed)."""
    n = max(len(e[0]) for e in envs)
    full, low, mid = np.zeros(n), np.zeros(n), np.zeros(n)
    for f, l, m in envs:
        full[: len(f)] += _norm(f)
        low[: len(l)] += _norm(l)
        mid[: len(m)] += _norm(m)
    fps = sr / HOP
    warnings: list[str] = []
    if np.max(full) <= 0 or n < fps * 2:
        return TempoResult(prior_bpm, 0.0, [], [], 0.0, 0.0, beats_per_bar, True, (prior_bpm, prior_bpm),
                           ["Not enough rhythmic content to estimate a tempo; using the default."])

    ac = librosa.autocorrelate(full - full.mean())
    ac = ac / ac[0] if ac[0] > 0 else ac
    bpms = np.arange(60.0, 200.0, 0.25)
    raw = np.array([_comb_score(ac, 60.0 / b * fps) for b in bpms])
    prior = np.exp(-0.5 * (np.log2(bpms / prior_bpm) / 0.9) ** 2)
    score = np.clip(raw, 0, None) * prior
    order = np.argsort(score)[::-1]
    best = float(bpms[order[0]])
    # Octave choice: electronic stems sit mostly in 80-160 BPM; the other octave is offered as an alternative.
    while best < 80:
        best *= 2
    while best >= 160:
        best /= 2
    # Confidence: margin over the best candidate that is not the same tempo (or its octave).
    rival = next((score[i] for i in order[1:] if min(abs(np.log2(bpms[i] / best) - k) for k in (-1, 0, 1)) > 0.03), 0.0)
    confidence = float(np.clip(1.0 - rival / (score[order[0]] + 1e-9), 0, 1))

    # Fine BPM (0.01) and phase by fitting a rigid grid to the envelope.
    fine = np.arange(best - 0.6, best + 0.6, 0.02)
    fits = [(_grid_fit(full, 60.0 / b * fps), b) for b in fine]
    (phase, _), best = max(fits, key=lambda t: t[0][1])
    best = float(best)
    period = 60.0 / best * fps
    beat_frames = np.arange(phase, n, period)
    beats = beat_frames / fps

    # Drift check: free beat tracking, then local tempo spread.
    _, tracked = librosa.beat.beat_track(onset_envelope=full, sr=sr, hop_length=HOP, bpm=best, tightness=100)
    tb = librosa.frames_to_time(tracked, sr=sr, hop_length=HOP)
    if len(tb) >= 24:
        iv = np.diff(tb)
        local = 60.0 / np.convolve(iv, np.ones(16) / 16, mode="valid")
        lo, hi = float(np.percentile(local, 10)), float(np.percentile(local, 90))
    else:
        lo = hi = best
    stable = (hi - lo) / best < 0.05
    if not stable:
        warnings.append(f"Tempo may change over time ({lo:.1f}-{hi:.1f} BPM). A single fixed grid may not fit; check the grid before quantising.")

    # Downbeat: kick-heavy beats with weak mid-band (snare/clap) are bar starts.
    db_phase, db_conf = 0, 0.0
    if len(beat_frames) >= beats_per_bar * 2:
        L = np.array([_interp(low, i) for i in beat_frames])
        M = np.array([_interp(mid, i) for i in beat_frames])
        ps = []
        for p in range(beats_per_bar):
            sel = lambda k: slice((p + k) % beats_per_bar, None, beats_per_bar)
            v = L[sel(0)].mean() - 0.5 * M[sel(0)].mean()
            if beats_per_bar == 4:
                v += 0.3 * L[sel(2)].mean() + 0.4 * (M[sel(1)].mean() + M[sel(3)].mean()) - 0.3 * M[sel(2)].mean()
            ps.append(v)
        ps = np.array(ps)
        db_phase = int(np.argmax(ps))
        srt = np.sort(ps)[::-1]
        db_conf = float(np.clip((srt[0] - srt[1]) / (abs(srt[0]) + 1e-9), 0, 1))
    downbeat = float(beats[db_phase]) if len(beats) else 0.0
    if db_conf < 0.15:
        warnings.append("Bar position is uncertain; set the first downbeat manually if bars look shifted.")
    alternatives = [round(c, 2) for c in (best / 2, best * 2) if 50 <= c <= 240]
    return TempoResult(best, confidence, alternatives, [float(b) for b in beats], downbeat, db_conf,
                       beats_per_bar, bool(stable), (lo, hi), warnings)
