"""Chooses and runs the pipeline for a stem's instrument class.

Long files are processed in overlapping chunks so memory stays bounded; notes
that cross a chunk boundary are joined, not cut.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

import numpy as np

from . import __version__, classify, drums, mono, poly
from .notes import Note

SR = 22050
DRUM_SR = 44100
CHUNK_SECONDS = 120.0
OVERLAP_SECONDS = 4.0


@dataclass
class Options:
    mode: str = "balanced"  # fast | balanced | high
    pitch_bends: bool = False
    allow_crepe: bool = True
    drum_sensitivity: float = 0.5  # 0..1


@dataclass
class Result:
    notes: list[Note]
    pipeline: str
    engine: str
    mode: str
    instrument: str
    seconds: float
    warnings: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        return {
            "notes": [n.to_json() for n in self.notes],
            "pipeline": self.pipeline,
            "engine": self.engine,
            "engine_version": __version__,
            "mode": self.mode,
            "instrument": self.instrument,
            "processing_seconds": round(self.seconds, 2),
            "warnings": self.warnings,
        }


def _engine_name(pipeline: str, mode: str, opts: Options, fmin: float) -> str:
    if pipeline == "poly":
        return f"Basic Pitch (ICASSP 2022, ONNX) / {mode}"
    if pipeline == "drums":
        return {"fast": "Band onset detector", "balanced": "Onsets + learned hit classifier",
                "high": "Onsets + learned hit classifier + masked-hit search"}[mode]
    if mode == "fast":
        return "YIN pitch track / fast"
    if mode == "balanced":
        return "Basic Pitch, one voice / balanced"
    tracker = "CREPE" if opts.allow_crepe and fmin >= 60 and mono._crepe_available() else "pYIN"
    return f"Basic Pitch + {tracker} fusion / high"


def _join(chunks: list[tuple[float, list[Note]]], overlap: float) -> list[Note]:
    """Merge chunked results without cutting notes at chunk edges.

    Each chunk owns the notes that start in its span (the overlap is split
    in half). A note in a later chunk that starts before that chunk's own
    span and has the same pitch as a note still sounding from the previous
    chunk is that note's continuation, so the earlier note is extended.
    """
    out: list[Note] = []
    for idx, (offset, notes) in enumerate(chunks):
        lo = offset + (overlap / 2 if idx > 0 else 0.0)
        hi = chunks[idx + 1][0] + overlap / 2 if idx + 1 < len(chunks) else float("inf")
        for n in notes:
            n.start += offset
            n.end += offset
        for n in notes:
            if lo <= n.start < hi:
                out.append(n)
            elif n.start < lo and n.drum is None:
                prev = [p for p in out if p.pitch == n.pitch and p.drum is None and p.start <= n.start + 0.05
                        and p.end >= offset - 0.05]
                if prev:
                    p = max(prev, key=lambda p: p.end)
                    p.end = max(p.end, n.end)
    out.sort(key=lambda n: (n.start, n.pitch))
    return out


def transcribe_signal(y: np.ndarray, sr: int, instrument: str, opts: Options, progress=None) -> Result:
    t0 = time.time()
    pipeline = classify.PIPELINE[instrument]
    fmin, fmax = classify.F0_RANGE.get(instrument, (30.0, 2100.0))
    warnings: list[str] = []
    total = len(y) / sr
    chunk = CHUNK_SECONDS if pipeline != "drums" else CHUNK_SECONDS * 2
    starts = [0.0]
    while starts[-1] + chunk < total:
        starts.append(starts[-1] + chunk - OVERLAP_SECONDS)
    results = []
    for k, start in enumerate(starts):
        a, b = int(start * sr), int(min(total, start + chunk) * sr)
        seg = y[a:b]

        def sub(frac, msg, k=k):
            if progress:
                progress((k + frac) / len(starts), msg + (f" (part {k + 1}/{len(starts)})" if len(starts) > 1 else ""))

        if pipeline == "poly":
            notes, w = poly.transcribe(seg, sr, opts.mode, progress=sub)
        elif pipeline == "drums":
            notes, w = drums.transcribe(seg, sr, opts.mode, opts.drum_sensitivity, progress=sub)
        else:
            notes, w = mono.transcribe(seg, sr, opts.mode, fmin, fmax, with_bends=opts.pitch_bends,
                                       allow_crepe=opts.allow_crepe, progress=sub)
        warnings.extend(w)
        results.append((start, notes))
    notes = _join(results, OVERLAP_SECONDS) if len(results) > 1 else results[0][1]
    if not notes:
        warnings.append("No notes were detected. Check the instrument type, or try High Accuracy.")
    if progress:
        progress(1.0, "Done")
    return Result(notes, pipeline, _engine_name(pipeline, opts.mode, opts, fmin), opts.mode, instrument,
                  time.time() - t0, warnings)


def transcribe_file(path: str, instrument: str, opts: Options, progress=None) -> Result:
    from . import audio_io

    sr = DRUM_SR if classify.PIPELINE[instrument] == "drums" else SR
    y, sr = audio_io.load(path, sr=sr)
    return transcribe_signal(y, sr, instrument, opts, progress)
