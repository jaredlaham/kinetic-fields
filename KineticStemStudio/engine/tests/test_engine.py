"""Engine tests. Accuracy floors sit a little under the measured scores in
docs/ACCURACY.md so a regression fails the suite; they are not claims."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import mido
import numpy as np
import pretty_midi
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "eval"))

from kstem import audio_io, tempo  # noqa: E402
from kstem.export import als, smf, t8  # noqa: E402
from kstem.notes import Note  # noqa: E402
from kstem.transcribe import Options, transcribe_file  # noqa: E402
from run_eval import GM_TO_CLASS, drum_scores, melodic_scores  # noqa: E402

FX = ROOT / "eval" / "fixtures"
MANIFEST = json.loads((FX / "manifest.json").read_text())


def _ref(name):
    pm = pretty_midi.PrettyMIDI(str(FX / f"{name}.mid"))
    return [n for i in pm.instruments for n in i.notes]


@pytest.mark.parametrize("name", list(MANIFEST))
def test_tempo_within_half_a_bpm(name):
    y, sr = audio_io.load(FX / f"{name}.flac")
    r = tempo.estimate([tempo.onset_envelopes(y, sr)])
    assert abs(r.bpm - MANIFEST[name]["bpm"]) < 0.5


FLOORS = {"mono_bass": 0.95, "analog_lead": 0.95, "poly_piano": 0.85, "arp_synth": 0.85, "acid_bassline": 0.7,
          "reverb_melody": 0.7, "four_floor": 0.88, "breakbeat": 0.85}


@pytest.mark.parametrize("name", list(FLOORS))
def test_balanced_note_f1_floor(name):
    meta = MANIFEST[name]
    res = transcribe_file(str(FX / f"{name}.flac"), meta["class"], Options(mode="balanced"))
    if meta["class"] == "drums":
        sc = drum_scores([(n.start, GM_TO_CLASS.get(n.pitch, "perc")) for n in _ref(name)],
                         [(n.start, n.drum) for n in res.notes])
    else:
        sc = melodic_scores(sorted((n.start, n.end, n.pitch) for n in _ref(name)),
                            sorted((n.start, n.end, n.pitch) for n in res.notes))
    assert sc["f1"] >= FLOORS[name], sc


def test_smf_round_trip_and_overlaps(tmp_path):
    notes = [dict(pitch=60, start=0.0, end=1.0, velocity=100), dict(pitch=60, start=0.5, end=1.5, velocity=90),
             dict(pitch=64, start=0.25, end=0.75, velocity=80, bends=[[0.0, 0.0], [0.1, 0.5], [0.2, 3.0]])]
    rep = smf.export([smf.TrackIn("Lead", 3, notes)], 120.0, (4, 4), 960, str(tmp_path / "a.mid"), "multitrack", "T")
    assert rep.validated, rep.problems
    assert any("limited" in w for w in rep.warnings)  # 3 semitones > +-2 bend range is reported
    mf = mido.MidiFile(str(tmp_path / "a.mid"))
    assert mf.type == 1 and mf.ticks_per_beat == 960
    back = smf.read_notes(str(tmp_path / "a.mid"))["Lead"]
    assert [(p, s, e) for p, s, e, _, _ in back] == [(60, 0, 960), (60, 960, 2880), (64, 480, 1440)]


def test_region_export(tmp_path):
    notes = [dict(pitch=40, start=0.5, end=1.5, velocity=100), dict(pitch=41, start=3.0, end=4.0, velocity=100)]
    rep = smf.export([smf.TrackIn("Bass", 2, notes)], 120.0, (4, 4), 480, str(tmp_path), "individual", "R", (1.0, 3.5))
    assert rep.validated and len(rep.files) == 1
    back = smf.read_notes(rep.files[0])["Bass"]
    assert [(p, s, e) for p, s, e, _, _ in back] == [(40, 0, 480), (41, 1920, 2400)]


def test_live_set_structure():
    plan = als.SetPlan(bpm=128.0, meter=(4, 4), midi=[als.TrackPlan("Bass (MIDI)", 22, als.MidiClip("Bass", 8, [
        als.ClipNote(36, 0, 0.5, 100), als.ClipNote(48, 0.5, 0.25, 90)]))],
        audio=[als.TrackPlan("Bass", 22, als.AudioClip("Bass", "Samples/Bass.wav", 44100 * 4, 44100, 10, 0))])
    data = als.build(plan)
    assert als.validate(data, plan) == []
    xml = als.gunzip(data)
    assert 'Creator="Ableton Live 12.4.6"' in xml
    clip = xml[xml.find('<MidiClip Id="2" Time="0"'):]
    assert clip.count("<MidiNoteEvent ") >= 2 and 'MemorizedFirstClipName Value="Bass"' in xml


def test_live_lite_track_limit():
    plan = als.SetPlan(120.0, (4, 4), [als.TrackPlan(f"m{i}", 1) for i in range(5)], [als.TrackPlan(f"a{i}", 1) for i in range(4)])
    with pytest.raises(als.AlsError):
        als.build(plan)


def test_t8_conversion_reports_everything():
    bpm = 120.0
    s16 = 60 / bpm / 4
    drums = [dict(pitch=36, start=k * 4 * s16, end=k * 4 * s16 + 0.1, velocity=120, drum="kick") for k in range(4)]
    drums += [dict(pitch=56, start=2 * s16, end=2 * s16 + 0.1, velocity=90, drum="perc")]
    bass = [dict(pitch=24, start=0.0, end=s16 * 1.2, velocity=127),  # slides into the next note
            dict(pitch=6, start=s16, end=2 * s16, velocity=90)]  # below range: moved up an octave
    conv = t8.convert(drums, bass, bpm, 0.0, steps=16)
    seg = conv.segments[0]
    assert [s.on for s in seg.drums["BD"]][:5] == [True, False, False, False, True]
    assert seg.bass[0].note == 24 and seg.bass[0].slide and seg.bass[0].accent
    assert seg.bass[1].note == 18
    text = " ".join(conv.report)
    assert "no T-8 voice" in text and "octaves" in text


def test_cli_protocol(tmp_path):
    req = {"path": str(FX / "mono_bass.flac"), "instrument": "bass_guitar", "mode": "fast"}
    p = subprocess.run([sys.executable, "-m", "kstem", "transcribe"], input=json.dumps(req), capture_output=True,
                       text=True, cwd=ROOT)
    lines = [json.loads(line) for line in p.stdout.strip().splitlines()]
    assert p.returncode == 0
    assert lines[-1]["event"] == "result" and lines[-1]["data"]["notes"]
    assert any(line["event"] == "progress" for line in lines)
    bad = subprocess.run([sys.executable, "-m", "kstem", "transcribe"], input=json.dumps({"path": "/nope.wav", "instrument": "piano"}),
                         capture_output=True, text=True, cwd=ROOT)
    assert bad.returncode == 1 and json.loads(bad.stdout.strip().splitlines()[-1])["event"] == "error"


def test_chunked_transcription_joins_notes():
    from kstem import transcribe

    sr = 22050
    t = np.arange(int(sr * 8)) / sr
    y = (0.5 * np.sin(2 * np.pi * 110 * t) * (t < 7.5)).astype(np.float32)
    old = transcribe.CHUNK_SECONDS, transcribe.OVERLAP_SECONDS
    transcribe.CHUNK_SECONDS, transcribe.OVERLAP_SECONDS = 4.0, 1.0
    try:
        res = transcribe.transcribe_signal(y, sr, "synth_bass", Options(mode="fast"))
    finally:
        transcribe.CHUNK_SECONDS, transcribe.OVERLAP_SECONDS = old
    long = [n for n in res.notes if n.pitch == 45]
    assert long and max(n.duration for n in long) > 6.5
