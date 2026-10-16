"""Standard MIDI File export with read-back validation.

Type 1 for multitrack (tempo map on track 0), one Type 1 file per track for
individual exports. Every written file is parsed again with mido and its
notes compared one by one with what was meant to be written.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import mido

BEND_RANGE = 2.0  # semitones; the General MIDI default


@dataclass
class TrackIn:
    name: str
    channel: int  # 1..16
    notes: list[dict]  # {pitch, start, end, velocity, bends?: [[t, semis], ...]}
    program: int | None = None
    is_drum: bool = False


@dataclass
class ExportReport:
    files: list[str] = field(default_factory=list)
    notes_written: int = 0
    validated: bool = False
    problems: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        return self.__dict__


def _ticks(seconds: float, bpm: float, tpq: int) -> int:
    return int(round(seconds * bpm / 60.0 * tpq))


def clip_region(tracks: list[TrackIn], region: tuple[float, float] | None, warnings: list[str]) -> list[TrackIn]:
    if not region:
        return tracks
    a, b = region
    out = []
    cut = 0
    for t in tracks:
        notes = []
        for n in t.notes:
            if n["end"] <= a or n["start"] >= b:
                continue
            m = dict(n)
            if m["start"] < a or m["end"] > b:
                cut += 1
            m["start"] = max(m["start"], a) - a
            m["end"] = min(m["end"], b) - a
            m["bends"] = [[bt - (max(n["start"], a) - n["start"]), v] for bt, v in n.get("bends", [])
                          if 0 <= bt - (max(n["start"], a) - n["start"]) <= m["end"] - m["start"]]
            notes.append(m)
        out.append(TrackIn(t.name, t.channel, notes, t.program, t.is_drum))
    if cut:
        warnings.append(f"{cut} notes crossing the region edges were shortened to fit the region")
    return out


def _expected(track: TrackIn, bpm: float, tpq: int) -> list[tuple[int, int, int, int, int]]:
    exp = []
    for n in track.notes:
        s, e = _ticks(n["start"], bpm, tpq), _ticks(n["end"], bpm, tpq)
        e = max(e, s + 1)
        exp.append((int(n["pitch"]), s, e, max(1, min(127, int(n["velocity"]))), track.channel - 1))
    return sorted(exp)


def _track_messages(track: TrackIn, bpm: float, tpq: int, warnings: list[str]) -> mido.MidiTrack:
    events = []  # (tick, order, message)
    ch = track.channel - 1
    if track.program is not None and not track.is_drum:
        events.append((0, 0, mido.Message("program_change", channel=ch, program=int(track.program))))
    # Notes on the same pitch must not overlap in MIDI: end the earlier one where the next starts.
    by_pitch: dict[int, list] = {}
    for n in track.notes:
        by_pitch.setdefault(int(n["pitch"]), []).append(n)
    clipped_bends = 0
    has_bends = False
    for pitch, ns in by_pitch.items():
        ns.sort(key=lambda n: n["start"])
        for i, n in enumerate(ns):
            s = _ticks(n["start"], bpm, tpq)
            e = max(_ticks(n["end"], bpm, tpq), s + 1)
            if i + 1 < len(ns):
                nxt = _ticks(ns[i + 1]["start"], bpm, tpq)
                if e > nxt:
                    e = max(s + 1, nxt)
                    n["end"] = e * 60.0 / bpm / tpq
            vel = max(1, min(127, int(n["velocity"])))
            events.append((s, 2, mido.Message("note_on", channel=ch, note=pitch, velocity=vel)))
            events.append((e, 1, mido.Message("note_off", channel=ch, note=pitch, velocity=64)))
            for bt, semis in n.get("bends", []):
                has_bends = True
                if abs(semis) > BEND_RANGE:
                    clipped_bends += 1
                value = int(round(max(-1.0, min(1.0, semis / BEND_RANGE)) * 8191))
                events.append((s + _ticks(bt, bpm, tpq), 3, mido.Message("pitchwheel", channel=ch, pitch=value)))
            if n.get("bends"):
                events.append((e, 0, mido.Message("pitchwheel", channel=ch, pitch=0)))
    if clipped_bends:
        warnings.append(f"{track.name}: {clipped_bends} pitch-bend points beyond +-{BEND_RANGE:g} semitones were limited")
    if has_bends and len({(n['start'], n['end']) for n in track.notes}) and _overlapping(track.notes):
        warnings.append(f"{track.name}: pitch bends apply to the whole channel; overlapping notes share them")
    events.sort(key=lambda e: (e[0], e[1]))
    mt = mido.MidiTrack()
    mt.append(mido.MetaMessage("track_name", name=track.name, time=0))
    last = 0
    for tick, _, msg in events:
        mt.append(msg.copy(time=tick - last))
        last = tick
    mt.append(mido.MetaMessage("end_of_track", time=0))
    return mt


def _overlapping(notes) -> bool:
    ns = sorted(notes, key=lambda n: n["start"])
    return any(ns[i + 1]["start"] < ns[i]["end"] for i in range(len(ns) - 1))


def _tempo_track(bpm: float, meter: tuple[int, int], name: str) -> mido.MidiTrack:
    t = mido.MidiTrack()
    t.append(mido.MetaMessage("track_name", name=name, time=0))
    t.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(bpm), time=0))
    t.append(mido.MetaMessage("time_signature", numerator=meter[0], denominator=meter[1], time=0))
    t.append(mido.MetaMessage("end_of_track", time=0))
    return t


def read_notes(path: str) -> dict[str, list[tuple[int, int, int, int, int]]]:
    """Notes per track name: (pitch, start_tick, end_tick, velocity, channel)."""
    mf = mido.MidiFile(path)
    out = {}
    for tr in mf.tracks:
        name = next((m.name for m in tr if m.type == "track_name"), "")
        tick = 0
        open_: dict[tuple[int, int], list[tuple[int, int]]] = {}
        notes = []
        for m in tr:
            tick += m.time
            if m.type == "note_on" and m.velocity > 0:
                open_.setdefault((m.channel, m.note), []).append((tick, m.velocity))
            elif m.type in ("note_off", "note_on"):
                stack = open_.get((m.channel, m.note))
                if stack:
                    s, v = stack.pop(0)
                    notes.append((m.note, s, tick, v, m.channel))
        out[name] = sorted(notes)
    return out


def write(tracks: list[TrackIn], bpm: float, meter: tuple[int, int], tpq: int, path: str, title: str) -> ExportReport:
    rep = ExportReport()
    mf = mido.MidiFile(type=1, ticks_per_beat=tpq)
    mf.tracks.append(_tempo_track(bpm, meter, title))
    for t in tracks:
        mf.tracks.append(_track_messages(t, bpm, tpq, rep.warnings))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    mf.save(path)
    rep.files.append(path)
    rep.notes_written = sum(len(t.notes) for t in tracks)
    # Read back and compare.
    back = read_notes(path)
    names = [t.name for t in tracks]
    if len(set(names)) != len(names):
        rep.problems.append("track names repeat; validation compares by order instead")
    mf2 = mido.MidiFile(path)
    if mf2.ticks_per_beat != tpq:
        rep.problems.append(f"resolution {mf2.ticks_per_beat} != {tpq}")
    tempos = [m.tempo for tr in mf2.tracks for m in tr if m.type == "set_tempo"]
    if not tempos or abs(mido.tempo2bpm(tempos[0]) - bpm) > 0.01:
        rep.problems.append("tempo did not survive the round trip")
    for t in tracks:
        got = back.get(t.name, [])
        exp = _expected(t, bpm, tpq)
        # Same-pitch overlaps were shortened on write; compare starts, pitches, velocities, channels.
        key = lambda n: (n[0], n[1], n[3], n[4])  # noqa: E731
        if sorted(map(key, got)) != sorted(map(key, exp)):
            rep.problems.append(f"{t.name}: {len(got)} notes read back, {len(exp)} expected, or values differ")
    rep.validated = not rep.problems
    return rep


def export(tracks: list[TrackIn], bpm: float, meter: tuple[int, int], tpq: int, out: str, layout: str,
           title: str, region=None) -> ExportReport:
    """layout: 'multitrack' -> one Type 1 file at `out`; 'individual' -> one file per track in directory `out`."""
    if tpq not in (96, 192, 240, 384, 480, 960, 1920):
        raise ValueError("ticks per quarter note must be one of 96, 192, 240, 384, 480, 960, 1920")
    warnings: list[str] = []
    tracks = clip_region(tracks, region, warnings)
    if layout == "multitrack":
        rep = write(tracks, bpm, meter, tpq, out, title)
    else:
        rep = ExportReport()
        for t in tracks:
            safe = "".join(c if c.isalnum() or c in " -_()" else "_" for c in t.name).strip() or "Track"
            r = write([t], bpm, meter, tpq, str(Path(out) / f"{title} - {safe}.mid"), title)
            rep.files += r.files
            rep.notes_written += r.notes_written
            rep.problems += r.problems
            rep.warnings += r.warnings
        rep.validated = not rep.problems
    rep.warnings = warnings + rep.warnings
    return rep
