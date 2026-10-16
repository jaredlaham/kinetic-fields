"""Ableton export: a native Live 12 set (template-based) or an import package.

Project Name/
  Project Name.als        native set (only in "native" mode)
  Samples/                copies of the original stems (sources are never modified)
  MIDI/                   one .mid per transcribed stem + "<Project> - All tracks.mid"
  Exports/                manifest.json, READ ME.txt
"""
from __future__ import annotations

import json
import os
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

import soundfile as sf

from . import als, smf

STEM_COLORS = {"drums": 3, "bass_guitar": 22, "synth_bass": 22, "mono_synth": 14, "poly_synth": 17, "piano": 18,
               "guitar": 9, "vocal": 26, "other_melodic": 13}


@dataclass
class StemIn:
    name: str
    path: str | None  # original audio
    instrument: str
    midi: smf.TrackIn | None  # None when not transcribed
    include_audio: bool = True


@dataclass
class AbletonReport:
    folder: str
    kind: str  # "native" | "package"
    files: list[str] = field(default_factory=list)
    tracks: list[str] = field(default_factory=list)
    left_off: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_json(self):
        return self.__dict__


def _safe(name: str) -> str:
    s = "".join(c if c.isalnum() or c in " -_()." else "_" for c in name).strip(" .")
    return s or "Untitled"


def _audio_frames(path: str) -> tuple[int, int]:
    try:
        i = sf.info(path)
        return int(i.frames), int(i.samplerate)
    except Exception:
        from .. import audio_io

        y, sr = audio_io.load(path, sr=None)
        return len(y), sr


def export(stems: list[StemIn], bpm: float, meter: tuple[int, int], title: str, parent: str, kind: str = "native",
           tpq: int = 480, overwrite: bool = False) -> AbletonReport:
    title = _safe(title)
    root = Path(parent) / title
    if root.exists() and not overwrite:
        raise FileExistsError(f"{root} already exists")
    tmp = Path(parent) / f".{title}.partial"
    if tmp.exists():
        shutil.rmtree(tmp)
    for sub in ("Samples", "MIDI", "Exports"):
        (tmp / sub).mkdir(parents=True)
    rep = AbletonReport(folder=str(root), kind=kind)
    manifest = {"title": title, "bpm": bpm, "meter": list(meter), "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "kind": kind, "tracks": [], "note": "All audio and MIDI start at the stems' first sample (bar 1)."}
    midi_tracks = [s.midi for s in stems if s.midi is not None]
    # MIDI files: one per stem and one multitrack file.
    for s in stems:
        entry = {"stem": s.name, "instrument": s.instrument}
        if s.path and s.include_audio:
            ext = Path(s.path).suffix.lower() or ".wav"
            dst = tmp / "Samples" / f"{_safe(s.name)}{ext}"
            shutil.copy2(s.path, dst)
            entry["audio"] = f"Samples/{dst.name}"
        if s.midi is not None:
            r = smf.write([s.midi], bpm, meter, tpq, str(tmp / "MIDI" / f"{_safe(s.name)}.mid"), title)
            rep.problems += r.problems
            rep.warnings += r.warnings
            entry["midi"] = f"MIDI/{_safe(s.name)}.mid"
            entry["midi_channel"] = s.midi.channel
            entry["notes"] = len(s.midi.notes)
        manifest["tracks"].append(entry)
    if midi_tracks:
        r = smf.write(midi_tracks, bpm, meter, tpq, str(tmp / "MIDI" / f"{title} - All tracks.mid"), title)
        rep.problems += r.problems
    if kind == "native":
        midi_plans, audio_plans = [], []
        budget = als.LIVE_LITE_TRACKS
        # Pair each stem's audio with its MIDI; MIDI first (the transcription is the point), then audio.
        for s in stems:
            if s.midi is not None and budget > 0:
                beats = max([n["end"] for n in s.midi.notes] + [0.0]) * bpm / 60.0
                if s.path:
                    frames, sr = _audio_frames(s.path)
                    beats = max(beats, frames / sr * bpm / 60.0)
                clip = als.MidiClip(name=f"{s.name} MIDI", beats=max(beats, 1.0), notes=[
                    als.ClipNote(int(n["pitch"]), n["start"] * bpm / 60.0, max(1e-3, (n["end"] - n["start"]) * bpm / 60.0),
                                 int(n["velocity"])) for n in s.midi.notes])
                midi_plans.append(als.TrackPlan(f"{s.name} (MIDI)", STEM_COLORS.get(s.instrument, 14), clip))
                rep.tracks.append(f"{s.name} (MIDI)")
                budget -= 1
            elif s.midi is not None:
                rep.left_off.append(f"MIDI/{_safe(s.name)}.mid")
        for s in stems:
            if s.path and s.include_audio and budget > 0:
                frames, sr = _audio_frames(s.path)
                ext = Path(s.path).suffix.lower() or ".wav"
                rel = f"Samples/{_safe(s.name)}{ext}"
                st = os.stat(s.path)
                clip = als.AudioClip(s.name, rel, frames, sr, st.st_size, int(st.st_mtime))
                audio_plans.append(als.TrackPlan(s.name, STEM_COLORS.get(s.instrument, 14), clip))
                rep.tracks.append(s.name)
                budget -= 1
            elif s.path and s.include_audio:
                rep.left_off.append(f"Samples/{_safe(s.name)}{Path(s.path).suffix.lower()}")
        plan = als.SetPlan(bpm=bpm, meter=meter, midi=midi_plans, audio=audio_plans)
        data = als.build(plan)
        problems = als.validate(data, plan)
        rep.problems += problems
        (tmp / f"{title}.als").write_bytes(data)
        if rep.left_off:
            rep.warnings.append(f"Live 12 Lite holds {als.LIVE_LITE_TRACKS} tracks: {len(rep.left_off)} files are in the folder but not on a track")
    (tmp / "Exports" / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (tmp / "Exports" / "READ ME.txt").write_text(_readme(title, bpm, meter, kind, manifest, rep))
    # The old folder is removed only once the new one is complete.
    old = Path(parent) / f".{title}.replaced"
    if root.exists():
        if old.exists():
            shutil.rmtree(old)
        os.replace(root, old)
    os.replace(tmp, root)
    if old.exists():
        shutil.rmtree(old)
    rep.files = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
    return rep


def _readme(title, bpm, meter, kind, manifest, rep) -> str:
    lines = [f"{title} - Kinetic Stem Studio export", ""]
    if kind == "native":
        lines += [
            f'Open "{title}.als" in Ableton Live 12. The set is at {bpm:g} BPM in {meter[0]}/{meter[1]}.',
            "Each MIDI track holds the transcribed notes as one clip at bar 1 in Arrangement view;",
            "each audio track holds the original stem at bar 1. MIDI tracks have no instrument: add one in Live.",
            "Audio clips are warped in Re-Pitch with markers at the first and last sample, so at this tempo",
            "they play at their own speed and stay aligned with the MIDI.",
        ]
        if rep.left_off:
            lines += ["", f"In the folder but not on a track (Live 12 Lite holds {als.LIVE_LITE_TRACKS} tracks):"]
            lines += [f"  {f}" for f in rep.left_off]
    else:
        lines += [
            "ABLETON IMPORT PACKAGE (not a Live Set).",
            "",
            "1. Create a new Live Set and set the tempo to " + f"{bpm:g} BPM, {meter[0]}/{meter[1]}.",
            "2. Turn warping off for the stems (or keep Re-Pitch): drag each file in Samples/ to its own audio track at bar 1.",
            f'3. Drag "MIDI/{title} - All tracks.mid" into the Arrangement at bar 1: Live creates one MIDI track per part.',
            "   Or drag the single-stem files from MIDI/ onto separate MIDI tracks at bar 1.",
            "4. Everything starts at the stems' first sample, so bar 1 lines up audio and MIDI.",
        ]
    lines += ["", "Tracks:"]
    for t in manifest["tracks"]:
        lines.append(f"  {t['stem']}: " + ", ".join(f"{k} {v}" for k, v in t.items() if k in ("audio", "midi", "midi_channel", "notes")))
    return "\n".join(lines) + "\n"
