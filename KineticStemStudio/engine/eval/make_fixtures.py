"""Builds the accuracy-test fixtures: known MIDI performances rendered to audio.

Each fixture is a ground-truth MIDI file plus the audio rendered from it. The
audio is made by renderers that share no code with the transcription engine:
FluidSynth playing the FluidR3 General MIDI SoundFont (MIT licence), and, for
the acid bassline, a small TB-303-style subtractive synth defined here.

    python eval/make_fixtures.py --out eval/fixtures

Needs `fluidsynth` on PATH and a GM SoundFont (FLUID_SF2 or
/usr/share/sounds/sf2/FluidR3_GM.sf2). The rendered FLAC files are committed,
so running the evaluation does not need FluidSynth.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pretty_midi
import soundfile as sf
from scipy import signal

SR = 44100
DEFAULT_SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"


def _beat(bpm: float) -> float:
    return 60.0 / bpm


def _midi(bpm: float) -> pretty_midi.PrettyMIDI:
    return pretty_midi.PrettyMIDI(initial_tempo=bpm)


def _add(inst: pretty_midi.Instrument, pitch: int, start: float, end: float, vel: int) -> None:
    inst.notes.append(pretty_midi.Note(velocity=int(vel), pitch=int(pitch), start=float(start), end=float(end)))


# ---------------------------------------------------------------- performances

def mono_bass(rng: np.random.Generator):
    """Finger bass: repeated notes, staccato, octave jumps, sustained notes."""
    bpm = 104.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=33, name="Bass")
    lead_in = 2 * q
    # (pitch, start in 8ths, length in 8ths)
    bar_a = [(40, 0, 1), (40, 1, 0.5), (40, 2, 1), (52, 3, 0.5), (43, 4, 2), (45, 6, 1), (47, 7, 0.5)]
    bar_b = [(36, 0, 3), (38, 3, 1), (40, 4, 0.5), (40, 5, 0.5), (40, 6, 0.5), (43, 7, 1)]
    for bar in range(8):
        pattern = bar_a if bar % 2 == 0 else bar_b
        for pitch, s, l in pattern:
            t = lead_in + bar * 4 * q + s * q / 2
            # Humanise timing a little: real players are not on the grid.
            t += rng.normal(0, 0.006)
            _add(inst, pitch, t, t + l * q / 2 * 0.92, rng.integers(80, 118))
    pm.instruments.append(inst)
    return pm, {"class": "bass_guitar", "bpm": bpm}


def analog_lead(rng: np.random.Generator):
    """Sawtooth lead: legato phrases, long and short notes, leaps."""
    bpm = 118.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=81, name="Lead")
    phrase = [(69, 0, 2), (72, 2, 1), (74, 3, 1), (76, 4, 3), (74, 7, 0.5), (72, 7.5, 0.5),
              (69, 8, 1.5), (67, 9.5, 0.5), (64, 10, 4), (62, 14, 1), (64, 15, 1)]
    t0 = 2 * q
    for rep in range(4):
        for pitch, s, l in phrase:
            p = pitch + (5 if rep == 2 else 0)
            t = t0 + rep * 16 * q + s * q
            _add(inst, p, t, t + l * q * 0.97, rng.integers(90, 115))
    pm.instruments.append(inst)
    return pm, {"class": "mono_synth", "bpm": bpm}


def poly_piano(rng: np.random.Generator):
    """Piano: chords with independent voice durations, a moving top line."""
    bpm = 92.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=0, name="Piano")
    chords = [[48, 55, 60, 64], [45, 52, 57, 60], [41, 48, 57, 60], [43, 50, 55, 59]]
    t0 = 2 * q
    for bar in range(8):
        chord = chords[bar % 4]
        start = t0 + bar * 4 * q
        # Bass voice held the whole bar, inner voices two beats, then re-struck.
        _add(inst, chord[0], start, start + 4 * q * 0.95, 88)
        for half in range(2):
            for p in chord[1:3]:
                s = start + half * 2 * q + rng.normal(0, 0.004)
                _add(inst, p, s, s + 2 * q * 0.9, rng.integers(60, 85))
        # Melody: quarter and eighth notes over the chord.
        mel = [chord[3] + 12, chord[3] + 14, chord[3] + 12, chord[2] + 12]
        lens = [1, 0.5, 0.5, 2] if bar % 2 else [1.5, 0.5, 1, 1]
        s = start
        for p, l in zip(mel, lens):
            _add(inst, p, s, s + l * q * 0.95, rng.integers(85, 110))
            s += l * q
    pm.instruments.append(inst)
    return pm, {"class": "piano", "bpm": bpm}


def arp_synth(rng: np.random.Generator):
    """16th-note synth arpeggio with overlapping notes and repeated pitches."""
    bpm = 128.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=81, name="Arp")
    shapes = [[57, 60, 64, 69], [53, 57, 60, 65], [55, 59, 62, 67], [52, 55, 59, 64]]
    order = [0, 1, 2, 3, 2, 1, 3, 3]  # includes a repeated top note
    t0 = 2 * q
    for bar in range(8):
        shape = shapes[(bar // 2) % 4]
        for step in range(16):
            p = shape[order[step % 8]] + (12 if step >= 12 and bar % 2 else 0)
            t = t0 + bar * 4 * q + step * q / 4
            _add(inst, p, t, t + q / 4 * 1.3, rng.integers(70, 110))  # 130% gate: overlaps
    pm.instruments.append(inst)
    return pm, {"class": "poly_synth", "bpm": bpm}


GM = {"kick": 36, "snare": 38, "clap": 39, "closed_hat": 42, "open_hat": 46, "low_tom": 45,
      "high_tom": 50, "rim": 37, "crash": 49, "ride": 51}


def _drum(inst, name, t, vel):
    _add(inst, GM[name], t, t + 0.08, vel)


def four_floor(rng: np.random.Generator):
    bpm = 124.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=0, is_drum=True, name="Drums")
    t0 = 2 * q
    for bar in range(8):
        b = t0 + bar * 4 * q
        for beat in range(4):
            _drum(inst, "kick", b + beat * q, 115)
            _drum(inst, "closed_hat", b + beat * q + q / 2, 70)
            if beat in (1, 3):
                _drum(inst, "clap", b + beat * q, 105)
        _drum(inst, "open_hat", b + 3 * q + 3 * q / 4, 80)
        if bar % 4 == 3:
            for i in range(4):
                _drum(inst, "snare", b + 3 * q + i * q / 4, 70 + 10 * i)
    pm.instruments.append(inst)
    return pm, {"class": "drums", "bpm": bpm}


def breakbeat(rng: np.random.Generator):
    bpm = 132.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=0, is_drum=True, name="Drums")
    s16 = q / 4
    kick = [0, 6, 10]
    snare = [4, 12]
    ghost = [7, 15]
    t0 = 2 * q
    for bar in range(8):
        b = t0 + bar * 16 * s16
        k = kick if bar % 2 == 0 else [0, 3, 10, 11]
        for s in k:
            _drum(inst, "kick", b + s * s16, 112)
        for s in snare:
            _drum(inst, "snare", b + s * s16, 110)
        for s in ghost:
            _drum(inst, "snare", b + s * s16, 45)
        for s in range(0, 16, 2):
            _drum(inst, "closed_hat", b + s * s16 + rng.normal(0, 0.004), int(rng.integers(60, 95)))
        if bar % 4 == 0:
            _drum(inst, "crash", b, 100)
        if bar % 4 == 3:
            _drum(inst, "high_tom", b + 13 * s16, 95)
            _drum(inst, "low_tom", b + 14 * s16, 100)
            _drum(inst, "rim", b + 15 * s16, 90)
    pm.instruments.append(inst)
    return pm, {"class": "drums", "bpm": bpm}


def acid_bassline(rng: np.random.Generator):
    """TB-303 style line: 16ths, octave jumps, slides (overlaps) and accents."""
    bpm = 135.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=38, name="Acid")
    s16 = q / 4
    # (step, pitch, length in steps, accent, slide-into-next)
    line = [(0, 36, 1, 1, 0), (2, 36, 1, 0, 0), (3, 48, 1, 1, 0), (5, 39, 2, 0, 1), (7, 41, 1, 0, 0),
            (8, 36, 1, 1, 0), (10, 43, 1, 0, 1), (11, 46, 1, 0, 0), (12, 36, 1, 0, 0), (13, 36, 1, 1, 0),
            (14, 48, 1, 0, 0), (15, 39, 1, 0, 0)]
    t0 = 2 * q
    for bar in range(8):
        for step, pitch, length, accent, slide in line:
            t = t0 + (bar * 16 + step) * s16
            end = t + length * s16 * (1.15 if slide else 0.5)
            _add(inst, pitch, t, end, 127 if accent else 90)
    pm.instruments.append(inst)
    return pm, {"class": "synth_bass", "bpm": bpm, "renderer": "acid"}


def reverb_melody(rng: np.random.Generator):
    """Vibraphone melody drowned in a long reverb tail."""
    bpm = 84.0
    q = _beat(bpm)
    pm = _midi(bpm)
    inst = pretty_midi.Instrument(program=11, name="Vibes")
    mel = [(72, 1), (74, 0.5), (76, 0.5), (79, 2), (77, 1), (76, 1), (74, 2), (72, 0.5), (71, 0.5), (69, 3),
           (72, 1), (76, 1), (81, 2), (79, 1), (77, 0.5), (76, 0.5), (74, 4)]
    t = 2 * q
    for _ in range(2):
        for p, l in mel:
            _add(inst, p, t, t + l * q * 0.9, rng.integers(75, 105))
            t += l * q
    pm.instruments.append(inst)
    return pm, {"class": "other_melodic", "bpm": bpm, "reverb": 2.8}


FIXTURES = {
    "mono_bass": mono_bass,
    "analog_lead": analog_lead,
    "poly_piano": poly_piano,
    "arp_synth": arp_synth,
    "four_floor": four_floor,
    "breakbeat": breakbeat,
    "acid_bassline": acid_bassline,
    "reverb_melody": reverb_melody,
}


# ------------------------------------------------------------------- rendering

def render_fluidsynth(pm: pretty_midi.PrettyMIDI, sf2: str) -> np.ndarray:
    exe = shutil.which("fluidsynth")
    if not exe:
        raise SystemExit("fluidsynth is not installed")
    with tempfile.TemporaryDirectory() as tmp:
        mid = Path(tmp) / "in.mid"
        wav = Path(tmp) / "out.wav"
        pm.write(str(mid))
        # Reverb and chorus off: dry stems. Reverb, where wanted, is added below.
        subprocess.run([exe, "-ni", "-q", "-R", "0", "-C", "0", "-g", "0.6", "-r", str(SR),
                        "-F", str(wav), sf2, str(mid)], check=True, capture_output=True)
        audio, sr = sf.read(str(wav), always_2d=True)
    assert sr == SR
    return audio.mean(axis=1)


def render_acid(pm: pretty_midi.PrettyMIDI) -> np.ndarray:
    """Saw oscillator, resonant low-pass with decaying envelope, accent, glide."""
    notes = sorted(pm.instruments[0].notes, key=lambda n: n.start)
    total = int((pm.get_end_time() + 1.0) * SR)
    freq = np.zeros(total)
    gate = np.zeros(total)
    accent = np.zeros(total)
    env_reset = np.zeros(total, dtype=bool)
    for i, n in enumerate(notes):
        a, b = int(n.start * SR), int(n.end * SR)
        f = 440.0 * 2 ** ((n.pitch - 69) / 12)
        prev = notes[i - 1] if i else None
        sliding = prev is not None and prev.end > n.start
        if sliding:
            # 60 ms glide from the previous pitch, no new envelope (303 slide).
            g = int(0.06 * SR)
            f0 = 440.0 * 2 ** ((prev.pitch - 69) / 12)
            seg = np.linspace(f0, f, min(g, b - a))
            freq[a:a + len(seg)] = seg
            freq[a + len(seg):b] = f
        else:
            freq[a:b] = f
            env_reset[a] = True
        gate[a:b] = 1.0
        accent[a:b] = 1.0 if n.velocity >= 120 else 0.0
    # Hold the last pitch after note-off so the release does not drop to 0 Hz.
    last = 55.0
    for i in range(total):
        if freq[i] == 0:
            freq[i] = last
        else:
            last = freq[i]
    phase = np.cumsum(freq / SR)
    saw = 2 * (phase - np.floor(phase + 0.5))
    # Filter envelope.
    env = np.zeros(total)
    level = 0.0
    decay = np.exp(-1.0 / (0.18 * SR))
    for i in range(total):
        if env_reset[i]:
            level = 1.0
        env[i] = level
        level *= decay
    cutoff = 300 + 2500 * env * (0.6 + 0.8 * accent)
    # Time-varying 2-pole resonant low-pass (state-variable filter).
    out = np.zeros(total)
    low = band = 0.0
    q = 0.25
    for i in range(total):
        f = 2 * np.sin(np.pi * min(cutoff[i], 8000) / SR)
        low += f * band
        high = saw[i] - low - q * band
        band += f * high
        out[i] = low
    amp_env = signal.lfilter([1 - 0.995], [1, -0.995], gate * (0.7 + 0.3 * accent))
    y = np.tanh(1.5 * out * amp_env)
    return y / np.max(np.abs(y)) * 0.7


def add_reverb(x: np.ndarray, seconds: float, rng: np.random.Generator, wet: float = 0.55) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = rng.normal(0, 1, n) * np.exp(-6.9 * t / seconds)
    ir = signal.lfilter([0.3], [1, -0.7], ir)  # darker tail
    ir /= np.sqrt(np.sum(ir ** 2))
    wet_sig = np.pad(signal.fftconvolve(x, ir), (0, 1))[: len(x) + n]
    dry = np.concatenate([x, np.zeros(n)])
    y = (1 - wet) * dry + wet * wet_sig * 3
    return y / np.max(np.abs(y)) * 0.8


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).parent / "fixtures"))
    ap.add_argument("--sf2", default=os.environ.get("FLUID_SF2", DEFAULT_SF2))
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, build in FIXTURES.items():
        rng = np.random.default_rng(sum(map(ord, name)))
        pm, meta = build(rng)
        if meta.get("renderer") == "acid":
            audio = render_acid(pm)
            meta["renderer"] = "built-in TB-303 style synth"
        else:
            audio = render_fluidsynth(pm, args.sf2)
            meta["renderer"] = f"FluidSynth + {Path(args.sf2).name}"
        if meta.get("reverb"):
            audio = add_reverb(audio, meta["reverb"], rng)
        audio = audio / max(1e-9, np.max(np.abs(audio))) * 0.8
        pm.write(str(out / f"{name}.mid"))
        sf.write(str(out / f"{name}.flac"), audio.astype(np.float32), SR, subtype="PCM_16")
        meta["notes"] = sum(len(i.notes) for i in pm.instruments)
        meta["seconds"] = round(len(audio) / SR, 2)
        manifest[name] = meta
        print(f"{name}: {meta['notes']} notes, {meta['seconds']} s ({meta['renderer']})")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
