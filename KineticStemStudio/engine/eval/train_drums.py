"""Trains the drum-hit classifier shipped in kstem/models/drum_classifier.npz.

    python eval/train_drums.py

Training audio is rendered with FluidSynth from random drum patterns played on
FluidR3 GM drum kits *other than* the Standard kit (program 0). The accuracy
fixtures use the Standard kit, so the evaluation measures generalisation to a
kit the classifier never heard. The model is one logistic regression per drum
class over spectral features taken at each detected onset (kstem.drums.hit_features),
so several classes can fire on one onset (kick + hat, snare + crash).
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pretty_midi
import soundfile as sf

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))

from kstem import drums  # noqa: E402

SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
SR = 44100
# FluidR3 GM drum kits (bank 128 programs), excluding 0 (Standard), which is held out.
TRAIN_KITS = [8, 16, 24, 25, 32, 40, 48]
NOTE_FOR = {
    "kick": [35, 36], "snare": [38, 40], "clap": [39], "rim": [37], "closed_hat": [42, 44], "open_hat": [46],
    "low_tom": [41, 43, 45], "high_tom": [47, 48, 50], "crash": [49, 57], "ride": [51, 59],
}
CLASS_OF = {n: c for c, ns in NOTE_FOR.items() for n in ns}


def random_pattern(rng: np.random.Generator, kit: int, bars: int = 24) -> pretty_midi.PrettyMIDI:
    bpm = float(rng.uniform(85, 150))
    pm = pretty_midi.PrettyMIDI(initial_tempo=bpm)
    inst = pretty_midi.Instrument(program=kit, is_drum=True)
    s16 = 60 / bpm / 4
    probs = {"kick": 0.28, "snare": 0.14, "clap": 0.07, "rim": 0.05, "closed_hat": 0.45, "open_hat": 0.07,
             "low_tom": 0.04, "high_tom": 0.04, "crash": 0.02, "ride": 0.06}
    for step in range(bars * 16):
        t = 0.5 + step * s16 + rng.normal(0, 0.003)
        for cls, p in probs.items():
            boost = 2.0 if (cls == "kick" and step % 4 == 0) or (cls in ("snare", "clap") and step % 8 == 4) else 1.0
            if rng.random() < p * boost:
                note = int(rng.choice(NOTE_FOR[cls]))
                inst.notes.append(pretty_midi.Note(int(rng.integers(35, 127)), note, t, t + 0.1))
    pm.instruments.append(inst)
    return pm


def render(pm: pretty_midi.PrettyMIDI) -> np.ndarray:
    with tempfile.TemporaryDirectory() as tmp:
        mid, wav = Path(tmp) / "a.mid", Path(tmp) / "a.wav"
        pm.write(str(mid))
        subprocess.run([shutil.which("fluidsynth"), "-ni", "-q", "-R", "0", "-C", "0", "-g", "0.6", "-r", str(SR),
                        "-F", str(wav), SF2, str(mid)], check=True, capture_output=True)
        y, _ = sf.read(str(wav), always_2d=True)
    y = y.mean(axis=1)
    return (y / (np.max(np.abs(y)) + 1e-9) * rng_gain()).astype(np.float32)


_g = np.random.default_rng(7)


def rng_gain() -> float:
    return float(_g.uniform(0.2, 0.9))


def dataset(rng, kits, reps):
    X, Y = [], []
    for kit in kits:
        for _ in range(reps):
            pm = random_pattern(rng, kit)
            y = render(pm)
            onsets = drums.detect_onsets(y, SR, sensitivity=0.6)
            feats = drums.hit_features(y, SR, onsets)
            hits = [(n.start, CLASS_OF[n.pitch]) for n in pm.instruments[0].notes]
            times = np.array([h[0] for h in hits])
            for t, f in zip(onsets, feats):
                lab = np.zeros(len(drums.LEARNED_CLASSES))
                near = np.nonzero(np.abs(times - t) < 0.03)[0]
                for i in near:
                    lab[drums.LEARNED_CLASSES.index(hits[i][1])] = 1
                X.append(f)
                Y.append(lab)
        print(f"kit {kit}: {len(X)} onsets so far", flush=True)
    return np.array(X, dtype=np.float32), np.array(Y, dtype=np.float32)


def train(X, Y, epochs=400, lr=0.05, l2=1e-3):
    mu, sd = X.mean(0), X.std(0) + 1e-6
    Xn = (X - mu) / sd
    W = np.zeros((X.shape[1], Y.shape[1]))
    b = np.zeros(Y.shape[1])
    pos = Y.mean(0).clip(1e-3, 1)
    wpos = (1 - pos) / pos  # balance rare classes
    m_w = v_w = np.zeros_like(W)
    m_b = v_b = np.zeros_like(b)
    for ep in range(1, epochs + 1):
        z = Xn @ W + b
        p = 1 / (1 + np.exp(-z))
        weight = np.where(Y > 0, np.sqrt(wpos), 1.0)
        g = (p - Y) * weight / len(X)
        gW = Xn.T @ g + l2 * W
        gb = g.sum(0)
        m_w = 0.9 * m_w + 0.1 * gW
        v_w = 0.999 * v_w + 0.001 * gW ** 2
        m_b = 0.9 * m_b + 0.1 * gb
        v_b = 0.999 * v_b + 0.001 * gb ** 2
        W -= lr * (m_w / (1 - 0.9 ** ep)) / (np.sqrt(v_w / (1 - 0.999 ** ep)) + 1e-8)
        b -= lr * (m_b / (1 - 0.9 ** ep)) / (np.sqrt(v_b / (1 - 0.999 ** ep)) + 1e-8)
    return W.astype(np.float32), b.astype(np.float32), mu.astype(np.float32), sd.astype(np.float32)


def report(X, Y, model, label):
    W, b, mu, sd = model
    p = 1 / (1 + np.exp(-(((X - mu) / sd) @ W + b)))
    for k, c in enumerate(drums.LEARNED_CLASSES):
        pred = p[:, k] > 0.5
        tp = np.sum(pred & (Y[:, k] > 0))
        P = tp / max(1, pred.sum())
        R = tp / max(1, (Y[:, k] > 0).sum())
        print(f"  {label} {c:11s} P {P:.2f} R {R:.2f} n={int(Y[:, k].sum())}")


if __name__ == "__main__":
    rng = np.random.default_rng(42)
    X, Y = dataset(rng, TRAIN_KITS, reps=3)
    model = train(X, Y)
    report(X, Y, model, "train")
    out = ROOT.parent / "kstem" / "models" / "drum_classifier.npz"
    out.parent.mkdir(exist_ok=True)
    W, b, mu, sd = model
    np.savez_compressed(out, W=W, b=b, mu=mu, sd=sd, classes=np.array(drums.LEARNED_CLASSES),
                        feature_version=np.array(drums.FEATURE_VERSION), kits=np.array(TRAIN_KITS))
    print("saved", out, X.shape)
