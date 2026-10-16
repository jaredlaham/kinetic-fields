"""Post-processing shared by the transcription pipelines.

Everything here works on lists of Note and never invents notes: it moves
onsets/offsets to better-supported positions, merges duplicates, or removes
notes that fail a stated test, and every removal is counted so the caller
can report it.
"""
from __future__ import annotations

from collections import Counter

import numpy as np

from .notes import Note


def amplitude_envelope(y: np.ndarray, sr: int, hop: int = 32) -> tuple[np.ndarray, float]:
    """Fine (~1.5 ms at 22.05 kHz) peak envelope used for onset/offset refinement."""
    n = len(y) // hop
    if n == 0:
        return np.zeros(1), hop / sr
    env = np.max(np.abs(y[: n * hop].reshape(n, hop)), axis=1)
    return env, hop / sr


def refine_onset(env: np.ndarray, step: float, t: float, before: float = 0.04, after: float = 0.03) -> float:
    """Move an onset to where the energy rise actually starts.

    Searches [t-before, t+after] for the steepest rise in the fine envelope,
    then walks back to where the envelope crosses 20 % of the rise's peak.
    """
    a = max(0, int((t - before) / step))
    b = min(len(env) - 1, int((t + after) / step))
    if b - a < 4:
        return t
    seg = env[a:b + 1]
    d = np.diff(seg)
    k = int(np.argmax(d))
    if d[k] <= 0:
        return t
    peak = float(np.max(seg[k:min(len(seg), k + int(0.03 / step) + 2)]))
    floor = float(np.min(seg[: k + 1]))
    thresh = floor + 0.2 * (peak - floor)
    j = k
    while j > 0 and seg[j] > thresh:
        j -= 1
    return (a + j) * step


def refine_onsets(notes: list[Note], y: np.ndarray, sr: int) -> None:
    env, step = amplitude_envelope(y, sr)
    for n in notes:
        new = refine_onset(env, step, n.start)
        if new < n.end - 0.01:
            n.start = new


def trim_tails(notes: list[Note], y: np.ndarray, sr: int, drop_db: float = 30.0) -> int:
    """Shorten notes whose end lies far into a decayed tail (reverb/delay).

    The end moves to where the note's band-limited level falls drop_db below
    the note's peak. Returns how many notes were shortened.
    """
    import librosa

    if not notes:
        return 0
    hop = 256
    C = np.abs(librosa.cqt(y, sr=sr, hop_length=hop, fmin=librosa.midi_to_hz(24), n_bins=96, bins_per_octave=12))
    db = librosa.amplitude_to_db(C, ref=np.max)
    changed = 0
    for n in notes:
        b = n.pitch - 24
        if not 0 <= b < db.shape[0]:
            continue
        a, e = int(n.start * sr / hop), int(n.end * sr / hop)
        if e - a < 4:
            continue
        row = db[b, a:e]
        peak = float(np.max(row[: max(2, len(row) // 3)]))
        below = np.nonzero(row < peak - drop_db)[0]
        below = below[below > int(0.05 * sr / hop)]
        if below.size:
            new_end = (a + int(below[0])) * hop / sr
            if new_end < n.end - 0.03:
                n.end = max(n.start + 0.03, new_end)
                changed += 1
    return changed


def merge_duplicates(notes: list[Note], gap: float = 0.03) -> int:
    """Merge same-pitch notes that overlap or touch (detector re-triggers)."""
    removed = 0
    by_pitch: dict[tuple[int, str | None], list[Note]] = {}
    for n in notes:
        by_pitch.setdefault((n.pitch, n.drum), []).append(n)
    keep: list[Note] = []
    for group in by_pitch.values():
        group.sort(key=lambda n: n.start)
        cur = group[0]
        for n in group[1:]:
            if n.start <= cur.end + gap and n.start - cur.start < 0.025:
                cur.end = max(cur.end, n.end)
                cur.velocity = max(cur.velocity, n.velocity)
                cur.confidence = max(cur.confidence, n.confidence)
                removed += 1
            elif n.start < cur.end:
                # Real re-strike: end the earlier note where the new one starts.
                cur.end = n.start
                keep.append(cur)
                cur = n
            else:
                keep.append(cur)
                cur = n
        keep.append(cur)
    notes[:] = sorted(keep, key=lambda n: (n.start, n.pitch))
    return removed


HARMONIC_INTERVALS = (12, 19, 24, 28, 31, 36)


def suppress_harmonics(notes: list[Note], conf_ratio: float = 0.9, subharmonics: bool = False) -> int:
    """Drop notes that sit on an overtone of a stronger note sounding at the same time.

    A note at +12, +19, +24, +28, +31 or +36 semitones above a note that is
    already sounding (or starts within 30 ms), overlaps at least half of its
    length, and has lower model confidence than conf_ratio x the lower note's,
    is treated as a harmonic false positive. Real octave doublings played
    as loud as the root survive this test. With subharmonics=True (one-voice
    material) a weaker note an interval *below* a sounding note that starts
    after it is dropped too.
    """
    drop = set()
    ordered = sorted(range(len(notes)), key=lambda i: notes[i].start)
    for ii, i in enumerate(ordered):
        hi = notes[i]
        for j in ordered[max(0, ii - 60): ii + 20]:
            lo = notes[j]
            if j == i or j in drop:
                continue
            if hi.pitch - lo.pitch not in HARMONIC_INTERVALS:
                if subharmonics and lo.pitch - hi.pitch in HARMONIC_INTERVALS and hi.start > lo.start + 0.03 \
                        and hi.confidence < conf_ratio * lo.confidence and hi.end > lo.start:
                    # hi is actually the lower note here (ghost below a sounding note).
                    drop.add(i)
                    break
                continue
            if lo.start > hi.start + 0.03:
                continue
            overlap = min(hi.end, lo.end) - max(hi.start, lo.start)
            if overlap < 0.5 * hi.duration:
                continue
            if hi.confidence < conf_ratio * lo.confidence:
                drop.add(i)
                break
    if drop:
        notes[:] = [n for k, n in enumerate(notes) if k not in drop]
    return len(drop)


def pitch_rise_db(y: np.ndarray, sr: int, hop: int = 256):
    """Returns f(pitch, t) -> dB increase of that pitch's CQT bin around time t (an attack test)."""
    import librosa

    C = np.abs(librosa.cqt(y, sr=sr, hop_length=hop, fmin=librosa.midi_to_hz(21), n_bins=88, bins_per_octave=12))
    db = librosa.amplitude_to_db(C, ref=np.max)

    def level(pitch: int, t0: float, t1: float) -> float:
        b = pitch - 21
        if not 0 <= b < db.shape[0]:
            return -120.0
        a, e = int(t0 * sr / hop), max(int(t0 * sr / hop) + 1, int(t1 * sr / hop))
        seg = db[b, a:e]
        return float(np.max(seg)) if seg.size else -120.0

    def rise(pitch: int, t: float) -> float:
        b = pitch - 21
        if not 0 <= b < db.shape[0]:
            return 0.0
        i = int(round(t * sr / hop))
        before = db[b, max(0, i - 6): max(1, i - 1)]
        after = db[b, i: i + 5]
        if before.size == 0 or after.size == 0:
            return 99.0
        return float(np.max(after) - np.min(before))

    rise.level = level  # type: ignore[attr-defined]
    return rise


def merge_false_retriggers(notes: list[Note], rise, min_rise_db: float = 4.0, gap: float = 0.08) -> int:
    """Join a note to the previous same-pitch note when no new attack is audible.

    Detectors often split one sustained note in two. If the second part
    starts within `gap` of the first part's end (or overlapping it) and the
    pitch's own band does not rise by min_rise_db at that point, it is the
    same note.
    """
    merged = 0
    by_pitch: dict[int, list[Note]] = {}
    for n in notes:
        by_pitch.setdefault(n.pitch, []).append(n)
    keep: list[Note] = []
    for group in by_pitch.values():
        group.sort(key=lambda n: n.start)
        cur = group[0]
        for n in group[1:]:
            if n.start - cur.end <= gap and rise(n.pitch, n.start) < min_rise_db:
                cur.end = max(cur.end, n.end)
                cur.confidence = max(cur.confidence, n.confidence)
                merged += 1
                continue
            keep.append(cur)
            cur = n
        keep.append(cur)
    notes[:] = sorted(keep, key=lambda n: (n.start, n.pitch))
    return merged


def min_duration(notes: list[Note], seconds: float) -> int:
    before = len(notes)
    notes[:] = [n for n in notes if n.duration >= seconds]
    return before - len(notes)


def limit_polyphony(notes: list[Note], max_voices: int) -> int:
    """Keep at most max_voices sounding notes, dropping the least confident."""
    events = sorted(notes, key=lambda n: n.start)
    active: list[Note] = []
    dropped = set()
    for n in events:
        active = [a for a in active if a.end > n.start + 1e-4 and id(a) not in dropped]
        active.append(n)
        while len(active) > max_voices:
            worst = min(active, key=lambda a: (a.confidence, a.velocity))
            dropped.add(id(worst))
            active.remove(worst)
    if dropped:
        notes[:] = [n for n in notes if id(n) not in dropped]
    return len(dropped)


def monophonic(notes: list[Note]) -> int:
    """Enforce one voice: overlapping notes end where the next begins (legato preserved as touch)."""
    notes.sort(key=lambda n: n.start)
    removed = 0
    out: list[Note] = []
    for n in notes:
        if out and n.start < out[-1].start + 0.015:
            # Same onset: keep the stronger one.
            if (n.confidence, n.velocity) > (out[-1].confidence, out[-1].velocity):
                out[-1] = n
            removed += 1
            continue
        if out and out[-1].end > n.start:
            out[-1].end = n.start
        out.append(n)
    notes[:] = out
    return removed


def velocity_from_rms(notes: list[Note], y: np.ndarray, sr: int, floor_db: float = -40.0) -> None:
    """Velocity from the peak RMS in the note's first 60 ms, mapped -40..0 dB -> 20..127."""
    hop = 128
    n_frames = len(y) // hop
    if n_frames == 0:
        return
    rms = np.sqrt(np.mean(y[: n_frames * hop].reshape(n_frames, hop) ** 2, axis=1) + 1e-12)
    ref = float(np.max(rms)) or 1.0
    for n in notes:
        a = int(n.start * sr / hop)
        b = max(a + 1, int((n.start + 0.06) * sr / hop))
        peak = float(np.max(rms[a:b])) if a < len(rms) else 0.0
        db = 20 * np.log10(peak / ref + 1e-9)
        n.velocity = int(np.clip(20 + (db - floor_db) / -floor_db * 107, 1, 127))


def summarize(removed: Counter) -> list[str]:
    labels = {
        "duplicates": "duplicate detections merged",
        "retriggers": "split notes re-joined (no new attack)",
        "rescued": "weak notes kept because their own pitch shows a clear attack",
        "harmonics": "harmonic (overtone) false positives removed",
        "short": "notes shorter than the minimum length removed",
        "polyphony": "notes over the polyphony limit removed",
        "threshold": "notes below the confidence threshold removed",
        "mono": "overlapping notes resolved to one voice",
        "tails": "note ends trimmed out of reverb tails",
        "exclusive": "weaker of two rarely-simultaneous drum classes dropped (e.g. snare vs clap)",
        "unclassified onsets": "onsets not confidently matched to any drum class (left out)",
    }
    return [f"{v} {labels.get(k, k)}" for k, v in removed.items() if v]
