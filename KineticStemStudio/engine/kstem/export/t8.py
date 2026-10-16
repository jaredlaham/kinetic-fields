"""Roland AIRA Compact T-8: converting drum and bass MIDI into T-8 patterns.

What this module relies on (see docs/T8.md for sources):
  * T-8 MIDI Implementation Chart v1.02: rhythm on channel 10, bass on
    channel 2 (defaults, both configurable on the unit); rhythm notes
    BD 36, SD 38, HC 50, TOM 47, CH 42, OH 46 (receive also 35/40/48/45/44);
    bass notes 12-96; clock/start/stop received; program change 0-63 selects
    patterns; no CC, no pitch bend, no SysEx.
  * Patterns hold up to 32 steps.

What it does not do: write patterns into the T-8's memory. Notes sent over
MIDI play the T-8's sounds; whether the T-8 records them into a pattern is
not documented and must be tested on the unit.

Every event that cannot be represented is listed in the report, never
dropped silently.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import mido

RHYTHM_NOTES = {"BD": 36, "SD": 38, "HC": 50, "TOM": 47, "CH": 42, "OH": 46}
VOICES = list(RHYTHM_NOTES)
# Default mapping from transcribed drum classes to T-8 voices (None = no T-8 voice).
DEFAULT_DRUM_MAP = {
    "kick": "BD", "snare": "SD", "clap": "HC", "rim": "SD", "closed_hat": "CH", "open_hat": "OH",
    "low_tom": "TOM", "high_tom": "TOM", "crash": "OH", "ride": "CH", "perc": None,
}
BASS_RANGE = (12, 96)
MAX_STEPS = 32
ACCENT_VELOCITY = 110


@dataclass
class Step:
    on: bool = False
    velocity: int = 0
    accent: bool = False


@dataclass
class BassStep:
    note: int | None = None  # None = rest
    tie: bool = False  # continues the previous note
    accent: bool = False
    slide: bool = False  # slides into the next note


@dataclass
class Segment:
    index: int
    start_seconds: float
    steps: int
    drums: dict[str, list[Step]]
    bass: list[BassStep]

    def to_json(self) -> dict:
        return {
            "index": self.index, "start_seconds": round(self.start_seconds, 4), "steps": self.steps,
            "drums": {v: [[int(s.on), s.velocity, int(s.accent)] for s in lane] for v, lane in self.drums.items()},
            "bass": [[s.note, int(s.tie), int(s.accent), int(s.slide)] for s in self.bass],
        }


@dataclass
class Conversion:
    segments: list[Segment]
    bpm: float
    report: list[str] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {"bpm": self.bpm, "segments": [s.to_json() for s in self.segments], "report": self.report,
                "counts": self.counts}


def convert(drum_notes: list[dict], bass_notes: list[dict], bpm: float, grid_start: float, steps: int = 16,
            segments: int | None = None, drum_map: dict | None = None, steps_per_beat: int = 4) -> Conversion:
    """Cut the performance into T-8 patterns of `steps` 16th-note steps starting at grid_start (a downbeat)."""
    if not 1 <= steps <= MAX_STEPS:
        raise ValueError(f"T-8 patterns hold 1-{MAX_STEPS} steps")
    dmap = {**DEFAULT_DRUM_MAP, **(drum_map or {})}
    step_s = 60.0 / bpm / steps_per_beat
    seg_s = steps * step_s
    ends = [n["end"] for n in drum_notes + bass_notes]
    total = max(ends) if ends else grid_start
    n_seg = segments or max(1, int((total - grid_start) // seg_s + (1 if (total - grid_start) % seg_s > 1e-6 else 0)))
    counts = {"drum_hits": 0, "drum_hits_unmapped": 0, "drum_hits_merged": 0, "bass_notes": 0,
              "bass_notes_transposed": 0, "bass_notes_overlapping": 0, "before_grid": 0, "after_last_segment": 0}
    report: list[str] = []
    max_shift = 0.0
    segs = [Segment(i, grid_start + i * seg_s, steps, {v: [Step() for _ in range(steps)] for v in VOICES},
                    [BassStep() for _ in range(steps)]) for i in range(n_seg)]
    unmapped_classes = set()

    def locate(t):
        rel = (t - grid_start) / step_s
        k = int(round(rel))
        return k // steps, k % steps, abs(rel - round(rel)) * step_s

    for n in drum_notes:
        counts["drum_hits"] += 1
        voice = dmap.get(n.get("drum") or "", None)
        if voice is None:
            counts["drum_hits_unmapped"] += 1
            unmapped_classes.add(n.get("drum") or "unknown")
            continue
        if n["start"] < grid_start - step_s / 2:
            counts["before_grid"] += 1
            continue
        seg, st, shift = locate(n["start"])
        if seg >= n_seg:
            counts["after_last_segment"] += 1
            continue
        max_shift = max(max_shift, shift)
        cell = segs[seg].drums[voice][st]
        if cell.on:
            counts["drum_hits_merged"] += 1
        cell.on = True
        cell.velocity = max(cell.velocity, int(n["velocity"]))
        cell.accent = cell.velocity >= ACCENT_VELOCITY

    bass_sorted = sorted(bass_notes, key=lambda n: n["start"])
    for i, n in enumerate(bass_sorted):
        counts["bass_notes"] += 1
        if n["start"] < grid_start - step_s / 2:
            counts["before_grid"] += 1
            continue
        seg, st, shift = locate(n["start"])
        if seg >= n_seg:
            counts["after_last_segment"] += 1
            continue
        max_shift = max(max_shift, shift)
        pitch = int(n["pitch"])
        while pitch < BASS_RANGE[0]:
            pitch += 12
            counts["bass_notes_transposed"] += 1
        while pitch > BASS_RANGE[1]:
            pitch -= 12
            counts["bass_notes_transposed"] += 1
        cell = segs[seg].bass[st]
        if cell.note is not None and not cell.tie:
            counts["bass_notes_overlapping"] += 1
            if int(n["velocity"]) <= (100 if cell.accent else 0):
                continue
        cell.note, cell.tie = pitch, False
        cell.accent = int(n["velocity"]) >= ACCENT_VELOCITY
        nxt = bass_sorted[i + 1] if i + 1 < len(bass_sorted) else None
        # Slide: the note is still sounding when the next one starts (legato), as on a TB-303.
        cell.slide = bool(nxt and n["end"] > nxt["start"] + 0.005)
        # Ties for the note's length beyond one step, within this segment.
        length_steps = int(round((n["end"] - n["start"]) / step_s))
        for k in range(1, length_steps):
            j = st + k
            if j >= steps:
                break
            nb = segs[seg].bass[j]
            if nb.note is None:
                nb.note, nb.tie = pitch, True

    if max_shift > 0.004:
        report.append(f"Timing was quantised to 16th-note steps; the largest move was {max_shift * 1000:.0f} ms.")
    if counts["drum_hits_unmapped"]:
        report.append(f"{counts['drum_hits_unmapped']} drum hits have no T-8 voice ({', '.join(sorted(unmapped_classes))}) and were not converted.")
    if counts["drum_hits_merged"]:
        report.append(f"{counts['drum_hits_merged']} drum hits landed on an already-used step of the same voice and were merged.")
    if counts["bass_notes_transposed"]:
        report.append(f"Bass notes outside the T-8 range 12-96 were moved by octaves ({counts['bass_notes_transposed']} octave moves).")
    if counts["bass_notes_overlapping"]:
        report.append(f"{counts['bass_notes_overlapping']} bass notes started on a step already holding a note (the T-8 bass is monophonic); the stronger note was kept.")
    if counts["before_grid"]:
        report.append(f"{counts['before_grid']} events before the first downbeat were not converted.")
    if counts["after_last_segment"]:
        report.append(f"{counts['after_last_segment']} events after the last pattern were not converted.")
    mapped = {k: v for k, v in dmap.items() if v}
    remaps = [f"{k} -> {v}" for k, v in mapped.items() if k in ("rim", "crash", "ride", "low_tom", "high_tom")]
    report.append("Drum mapping: " + ", ".join(f"{k} -> {v}" for k, v in mapped.items()) + ".")
    if remaps:
        report.append("Remapped because the T-8 has no matching voice: " + ", ".join(remaps) + ".")
    return Conversion(segs, bpm, report, counts)


def to_midi(conv: Conversion, path: str, rhythm_channel: int = 10, bass_channel: int = 2, tpq: int = 480,
            gate: float = 0.5) -> str:
    """Write the patterns as a Type 1 MIDI file using T-8 note numbers and channels (Mode A)."""
    mf = mido.MidiFile(type=1, ticks_per_beat=tpq)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(conv.bpm), time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    mf.tracks.append(meta)
    step_ticks = tpq // 4
    rhythm, bass = [], []
    offset = 0
    for seg in conv.segments:
        for v, lane in seg.drums.items():
            for i, s in enumerate(lane):
                if s.on:
                    t = offset + i * step_ticks
                    vel = 127 if s.accent else max(1, min(126, s.velocity))
                    rhythm += [(t, 1, mido.Message("note_on", channel=rhythm_channel - 1, note=RHYTHM_NOTES[v], velocity=vel)),
                               (t + step_ticks // 2, 0, mido.Message("note_off", channel=rhythm_channel - 1, note=RHYTHM_NOTES[v]))]
        i = 0
        while i < seg.steps:
            s = seg.bass[i]
            if s.note is not None and not s.tie:
                j = i + 1
                while j < seg.steps and seg.bass[j].tie:
                    j += 1
                start = offset + i * step_ticks
                end = offset + j * step_ticks if (s.slide or j > i + 1) else start + int(step_ticks * gate)
                if s.slide:
                    end += step_ticks // 4  # overlap the next note: legato = slide
                vel = 127 if s.accent else 90
                bass += [(start, 1, mido.Message("note_on", channel=bass_channel - 1, note=s.note, velocity=vel)),
                         (end, 0, mido.Message("note_off", channel=bass_channel - 1, note=s.note))]
                i = j
            else:
                i += 1
        offset += seg.steps * step_ticks
    for name, events in (("T-8 Rhythm", rhythm), ("T-8 Bass", bass)):
        tr = mido.MidiTrack()
        tr.append(mido.MetaMessage("track_name", name=name, time=0))
        last = 0
        for t, _, m in sorted(events, key=lambda e: (e[0], e[1])):
            tr.append(m.copy(time=t - last))
            last = t
        mf.tracks.append(tr)
    mf.save(path)
    return path
