"""Monophonic transcription for bass, leads and vocals.

Pipelines per mode (measured results in docs/ACCURACY.md):
  fast      YIN pitch track (librosa) with an energy gate; no model.
  balanced  Basic Pitch notes reduced to one voice: overtone and ghost-note
            filtering, sample-level onset refinement.
  high      balanced fused with a pitch track (pYIN, or CREPE via torchcrepe
            when installed and the range allows: CREPE starts at 32.7 Hz, too
            close to bass E1) so pitch changes without a new attack (slides,
            legato) become notes, plus optional bend curves.

Pitch changes without a new attack become touching (legato) notes, which is
also how slides are represented for T-8 export. Vibrato stays inside one
note; with pitch bends enabled it is kept as a bend curve, not split into
short notes.
"""
from __future__ import annotations

from collections import Counter

import librosa
import numpy as np
from scipy.ndimage import median_filter

from . import post
from .notes import Note

MODES = {
    "fast": dict(tracker="yin", hop=256, min_note=0.08, split_onsets=False, octave_check=False, refine=False),
    "balanced": dict(attacks_only=True),
    "high": dict(fusion=True, track_mode="pyin", min_note=0.04, octave_check=False),
    # The pitch-track-only pipeline, used inside "high" and kept for comparison.
    "pyin": dict(tracker="pyin", hop=256, min_note=0.05, split_onsets=True, octave_check=False, refine=True),
}


def _crepe_available() -> bool:
    try:
        import torchcrepe  # noqa: F401

        return True
    except Exception:
        return False


def pitch_track(y: np.ndarray, sr: int, tracker: str, hop: int, fmin: float, fmax: float):
    """Returns (times, midi_float or nan, voiced_prob)."""
    frame = 2048 if fmin < 60 else 1024
    if tracker == "yin":
        f0 = librosa.yin(y, fmin=fmin, fmax=fmax, sr=sr, frame_length=frame, hop_length=hop)
        rms = librosa.feature.rms(y=y, frame_length=frame, hop_length=hop)[0][: len(f0)]
        prob = np.clip(rms / (0.1 * np.max(rms) + 1e-9), 0, 1)
        voiced = rms > 0.04 * np.max(rms)
        f0 = np.where(voiced, f0, np.nan)
    elif tracker == "crepe":
        import torch
        import torchcrepe

        audio = torch.tensor(librosa.resample(y, orig_sr=sr, target_sr=16000))[None]
        h = int(hop * 16000 / sr)
        f, per = torchcrepe.predict(audio, 16000, h, max(fmin, 32.7), fmax, "full", batch_size=512,
                                    device="cpu", return_periodicity=True, decoder=torchcrepe.decode.viterbi)
        per = torchcrepe.filter.median(per, 3)[0].numpy()
        f = f[0].numpy()
        rms = librosa.feature.rms(y=librosa.resample(y, orig_sr=sr, target_sr=16000), frame_length=1024, hop_length=h)[0]
        n = min(len(f), len(rms))
        f, per, rms = f[:n], per[:n], rms[:n]
        voiced = (per > 0.45) & (rms > 0.02 * np.max(rms))
        f0 = np.where(voiced, f, np.nan)
        prob = per
    else:
        f0, voiced, prob = librosa.pyin(y, fmin=fmin, fmax=fmax, sr=sr, frame_length=frame, hop_length=hop,
                                        switch_prob=0.02, no_trough_prob=0.01)
        rms = librosa.feature.rms(y=y, frame_length=frame, hop_length=hop)[0][: len(f0)]
        gate = rms > 0.02 * np.max(rms)
        f0 = np.where(voiced & gate, f0, np.nan)
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=hop)
    midi = librosa.hz_to_midi(f0)
    return times, midi, np.nan_to_num(prob)


def _octave_fix(notes: list[Note], y: np.ndarray, sr: int) -> int:
    """Re-check each note's octave against the spectrum.

    If the fundamental an octave below has real energy and its harmonics
    explain the spectrum at least as well (harmonic sum), the note is moved
    down; if the claimed fundamental is nearly absent while its octave above
    carries the harmonic series, it is moved up. Returns the number changed.
    """
    changed = 0
    n_fft = 8192
    for n in notes:
        a = int(n.start * sr)
        b = min(len(y), a + max(n_fft, int(0.25 * sr)))
        seg = y[a:b]
        if len(seg) < n_fft // 2:
            continue
        spec = np.abs(np.fft.rfft(seg[:n_fft] * np.hanning(min(len(seg), n_fft)), n=n_fft))
        freqs = np.fft.rfftfreq(n_fft, 1 / sr)

        def energy(f):
            i = int(round(f / (sr / n_fft)))
            return float(np.max(spec[max(0, i - 2): i + 3])) if 0 < i < len(spec) - 3 else 0.0

        def hsum(f0, k=6):
            return sum(energy(f0 * h) / h ** 0.5 for h in range(1, k + 1))

        f = librosa.midi_to_hz(n.pitch)
        here, below, above = hsum(f), hsum(f / 2), hsum(f * 2)
        e_f, e_half = energy(f), energy(f / 2)
        peak = float(np.max(spec)) + 1e-9
        if f / 2 > 27 and e_half > 0.25 * peak and below > 1.05 * here:
            n.pitch -= 12
            changed += 1
        elif e_f < 0.05 * peak and above > 1.2 * here:
            n.pitch += 12
            changed += 1
    return changed


def segment(times, midi, prob, onsets: np.ndarray, hop_s: float, min_note: float, with_bends: bool) -> list[Note]:
    """Turn a pitch track into notes.

    A note starts at voicing onset, at a detected attack (repeated notes), or
    when the rounded pitch moves for at least 3 consecutive frames (a legato
    change or slide). Vibrato within +-0.6 semitone does not split notes.
    """
    voiced = ~np.isnan(midi)
    sm = midi.copy()
    if voiced.any():
        filled = np.where(voiced, midi, 0.0)
        sm = np.where(voiced, median_filter(filled, size=5), np.nan)
    onset_frames = set(np.round(onsets / hop_s).astype(int).tolist())
    notes: list[Note] = []
    cur_start = None
    cur_vals: list[float] = []
    cur_conf: list[float] = []
    cur_center = None
    pending = 0

    def close(end_i):
        nonlocal cur_start, cur_vals, cur_conf
        if cur_start is None:
            return
        start_t = times[cur_start]
        end_t = times[min(end_i, len(times) - 1)]
        if end_t - start_t >= min_note and cur_vals:
            pitch = int(np.round(np.median(cur_vals)))
            note = Note(pitch=pitch, start=float(start_t), end=float(end_t), velocity=96,
                        confidence=float(np.mean(cur_conf)))
            if with_bends:
                seg = np.array(cur_vals) - pitch
                if np.max(np.abs(seg)) > 0.25:
                    step = max(1, int(0.01 / hop_s))
                    note.bends = [(float(times[cur_start + k] - start_t), float(seg[k])) for k in range(0, len(seg), step)]
            notes.append(note)
        cur_start, cur_vals, cur_conf = None, [], []

    for i in range(len(sm)):
        if not voiced[i]:
            close(i)
            cur_center = None
            pending = 0
            continue
        v = sm[i]
        attack = any((i + d) in onset_frames for d in (-1, 0, 1))
        if cur_start is None:
            cur_start, cur_center = i, v
        elif attack and i - cur_start > max(2, int(0.04 / hop_s)):
            close(i)
            cur_start, cur_center = i, v
        elif abs(v - cur_center) > 0.6:
            pending += 1
            if pending >= 3:
                close(i - 2)
                cur_start, cur_center, pending = i - 2, v, 0
                cur_vals = list(sm[i - 2:i])
                cur_conf = list(prob[i - 2:i])
        else:
            pending = 0
            cur_center = 0.9 * cur_center + 0.1 * v
        cur_vals.append(float(midi[i]) if not np.isnan(midi[i]) else float(v))
        cur_conf.append(float(prob[i]))
    close(len(sm) - 1)
    return notes


def basic_pitch_mono(y: np.ndarray, sr: int, fmin: float, fmax: float) -> list[Note]:
    """Basic Pitch notes reduced to one voice (overtones dropped first)."""
    from . import poly

    out = poly.model_output(y, sr)
    notes = poly.decode(out, "mono", fmin=fmin * 0.95 if fmin > 32 else None, fmax=fmax * 1.05)
    # Ghost notes below a sounding note are only filtered above the bass
    # register: for bass the fundamental is often weaker than its octave.
    post.suppress_harmonics(notes, subharmonics=fmin >= 45)
    post.monophonic(notes)
    return notes


def fuse(attack_notes: list[Note], tracked: list[Note], rise=None) -> tuple[list[Note], int, int]:
    """Combine attack-based notes (Basic Pitch) with pitch-track notes (pYIN).

    Basic Pitch finds attacks reliably but misses pitch changes that have no
    new attack (slides, legato, hammer-ons). The pitch track sees those.
    A tracked note inside an attack note with a different pitch splits it
    (legato change); a confident tracked note where nothing was found is added.
    With `rise` (post.pitch_rise_db) both are checked against the spectrum: a
    legato split needs the old pitch to fall away and the new one to appear,
    so a reverb tail under the next note does not create a split.
    Returns (notes, legato_splits, added).
    """

    def real_change(old: int, new: int, t: float) -> bool:
        if rise is None:
            return True
        lv = rise.level
        old_drop = lv(old, t - 0.08, t - 0.01) - lv(old, t + 0.04, t + 0.12)
        new_gain = lv(new, t + 0.02, t + 0.10) - lv(new, t - 0.08, t - 0.01)
        return old_drop >= 6.0 and new_gain >= 6.0
    out = sorted((Note(**{**n.__dict__}) for n in attack_notes), key=lambda n: n.start)
    splits = added = 0
    for b in sorted(tracked, key=lambda n: n.start):
        if any(abs(a.start - b.start) < 0.05 for a in out):
            continue
        host = next((a for a in out if a.start + 0.05 < b.start < a.end - 0.03), None)
        if host is not None:
            if b.pitch != host.pitch and b.duration >= 0.06 and real_change(host.pitch, b.pitch, b.start):
                end = host.end
                host.end = b.start
                out.append(Note(pitch=b.pitch, start=b.start, end=max(b.end, b.start + 0.06) if b.end < end else end,
                                velocity=host.velocity, confidence=min(host.confidence, b.confidence), bends=b.bends))
                splits += 1
            continue
        overlaps = any(min(a.end, b.end) - max(a.start, b.start) > 0.5 * b.duration for a in out)
        if not overlaps and b.duration >= 0.08 and b.confidence >= 0.5 and (rise is None or rise(b.pitch, b.start) >= 6.0):
            out.append(b)
            added += 1
        out.sort(key=lambda n: n.start)
    out.sort(key=lambda n: n.start)
    return out, splits, added


def transcribe(y: np.ndarray, sr: int, mode: str, fmin: float, fmax: float, with_bends: bool = False,
               allow_crepe: bool = True, progress=None) -> tuple[list[Note], list[str]]:
    cfg = MODES[mode]
    if cfg.get("attacks_only"):
        if progress:
            progress(0.1, "Finding notes (Basic Pitch, one voice)")
        notes = basic_pitch_mono(y, sr, fmin, fmax)
        starts = [n.start for n in notes]
        post.refine_onsets(notes, y, sr)
        for k in range(1, len(notes)):
            notes[k].start = max(notes[k].start, starts[k - 1] + 0.02)
        post.monophonic(notes)
        post.velocity_from_rms(notes, y, sr)
        return notes, []
    if cfg.get("fusion"):
        return transcribe_fused(y, sr, mode, fmin, fmax, with_bends, allow_crepe, progress)
    tracker = cfg["tracker"]
    if progress:
        progress(0.05, f"Tracking pitch ({tracker.upper() if tracker != 'pyin' else 'pYIN'})")
    times, midi, prob = pitch_track(y, sr, tracker, cfg["hop"], fmin, fmax)
    hop_s = cfg["hop"] / sr
    onsets = np.array([])
    if cfg["split_onsets"]:
        if progress:
            progress(0.6, "Detecting attacks for repeated notes")
        oenv = librosa.onset.onset_strength(y=y, sr=sr, hop_length=cfg["hop"])
        onsets = librosa.onset.onset_detect(onset_envelope=oenv, sr=sr, hop_length=cfg["hop"], units="time",
                                            backtrack=False, delta=0.2)
    notes = segment(times, midi, prob, onsets, hop_s, cfg["min_note"], with_bends)
    removed: Counter = Counter()
    if cfg["octave_check"]:
        if progress:
            progress(0.8, "Checking octaves against the spectrum")
        removed["octave corrections"] += _octave_fix(notes, y, sr)
    if cfg["refine"]:
        post.refine_onsets(notes, y, sr)
    removed["mono"] += post.monophonic(notes)
    post.velocity_from_rms(notes, y, sr)
    return notes, post.summarize(removed)


def transcribe_fused(y, sr, mode, fmin, fmax, with_bends, allow_crepe, progress=None):
    cfg = MODES[mode]
    removed: Counter = Counter()
    if progress:
        progress(0.05, "Finding attacks (Basic Pitch)")
    attacks = basic_pitch_mono(y, sr, fmin, fmax)
    if progress:
        progress(0.35, "Tracking pitch for slides and legato")
    sub = dict(MODES[cfg["track_mode"]])
    tracker = "crepe" if allow_crepe and fmin >= 60 and _crepe_available() else sub["tracker"]
    times, midi, prob = pitch_track(y, sr, tracker, sub["hop"], fmin, fmax)
    tracked = segment(times, midi, prob, np.array([n.start for n in attacks]), sub["hop"] / sr, sub["min_note"], with_bends)
    notes, splits, added = fuse(attacks, tracked, post.pitch_rise_db(y, sr))
    removed["legato pitch changes found by the pitch track"] += splits
    removed["notes recovered from the pitch track"] += added
    if with_bends:
        # Attach bend curves from the pitch track to the attack-based notes.
        for n in notes:
            if not n.bends:
                sel = (times >= n.start) & (times < n.end) & ~np.isnan(midi)
                dev = midi[sel] - n.pitch
                if dev.size and np.max(np.abs(dev)) > 0.25:
                    step = max(1, int(0.01 * sr / sub["hop"]))
                    n.bends = [(float(t - n.start), float(d)) for t, d in zip(times[sel][::step], dev[::step])]
    if progress:
        progress(0.8, "Checking octaves and refining onsets")
    if cfg["octave_check"]:
        removed["octave corrections"] += _octave_fix(notes, y, sr)
    starts = [n.start for n in notes]
    post.refine_onsets(notes, y, sr)
    # Never let refinement move an onset before the previous note's start.
    for k in range(1, len(notes)):
        notes[k].start = max(notes[k].start, starts[k - 1] + 0.02)
    removed["mono"] += post.monophonic(notes)
    removed["short"] += post.min_duration(notes, 0.03)
    post.velocity_from_rms(notes, y, sr)
    return notes, post.summarize(removed)
