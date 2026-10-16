"""Accuracy evaluation against the ground-truth fixtures.

    python eval/run_eval.py [--modes fast,balanced,high] [--only name,...] [--out eval/results]

Melodic stems use mir_eval's note-transcription metrics (onset tolerance
50 ms, pitch tolerance 50 cents; "with offsets" also requires the offset
within 20 % of the note length or 50 ms). Drum stems are scored per class
with a 50 ms onset tolerance; drum-class accuracy is the share of hits whose
onset matched a reference hit (any class) that also got the right class.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import mir_eval
import numpy as np
import pretty_midi

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))

from kstem import audio_io, tempo  # noqa: E402
from kstem.transcribe import Options, transcribe_file  # noqa: E402

GM_TO_CLASS = {35: "kick", 36: "kick", 37: "rim", 38: "snare", 40: "snare", 39: "clap", 42: "closed_hat",
               44: "closed_hat", 46: "open_hat", 41: "low_tom", 43: "low_tom", 45: "low_tom", 47: "low_tom",
               48: "high_tom", 50: "high_tom", 49: "crash", 57: "crash", 51: "ride", 59: "ride"}
TOL = 0.05


def _arrays(notes):
    iv = np.array([[n[0], max(n[1], n[0] + 1e-3)] for n in notes]) if notes else np.zeros((0, 2))
    hz = np.array([librosa_midi_to_hz(n[2]) for n in notes]) if notes else np.zeros(0)
    return iv, hz


def librosa_midi_to_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def melodic_scores(ref, est):
    ri, rp = _arrays(ref)
    ei, ep = _arrays(est)
    if len(ei) == 0:
        return dict(precision=0, recall=0, f1=0, f1_offset=0, onset_f1=0, pitch_acc=0, onset_mae_ms=None,
                    offset_mae_ms=None, ref_notes=len(ref), est_notes=0)
    p, r, f, _ = mir_eval.transcription.precision_recall_f1_overlap(ri, rp, ei, ep, onset_tolerance=TOL, offset_ratio=None)
    _, _, fo, _ = mir_eval.transcription.precision_recall_f1_overlap(ri, rp, ei, ep, onset_tolerance=TOL)
    _, _, of = mir_eval.transcription.onset_precision_recall_f1(ri, ei, onset_tolerance=TOL)
    # Pitch accuracy: among onset-matched pairs (pitch ignored), share with the correct pitch.
    pairs = mir_eval.transcription.match_note_onsets(ri, ei, onset_tolerance=TOL)
    pitch_ok = [round(12 * np.log2(rp[i] / 440) ) == round(12 * np.log2(ep[j] / 440)) for i, j in pairs]
    full = mir_eval.transcription.match_notes(ri, rp, ei, ep, onset_tolerance=TOL, offset_ratio=None)
    on_err = [abs(ri[i][0] - ei[j][0]) * 1000 for i, j in full]
    off_err = [abs(ri[i][1] - ei[j][1]) * 1000 for i, j in full]
    return dict(precision=p, recall=r, f1=f, f1_offset=fo, onset_f1=of,
                pitch_acc=float(np.mean(pitch_ok)) if pitch_ok else 0.0,
                onset_mae_ms=float(np.mean(on_err)) if on_err else None,
                offset_mae_ms=float(np.median(off_err)) if off_err else None,
                ref_notes=len(ref), est_notes=len(est))


def drum_scores(ref, est):
    """ref/est: lists of (time, class)."""
    classes = sorted({c for _, c in ref} | {c for _, c in est})
    per = {}
    tp_all = fp_all = fn_all = 0
    for c in classes:
        r = np.array([t for t, k in ref if k == c])
        e = np.array([t for t, k in est if k == c])
        if len(r) == 0 and len(e) == 0:
            continue
        matched = 0
        if len(r) and len(e):
            iv_r = np.stack([r, r + 0.1], 1)
            iv_e = np.stack([e, e + 0.1], 1)
            matched = len(mir_eval.transcription.match_note_onsets(iv_r, iv_e, onset_tolerance=TOL))
        p = matched / len(e) if len(e) else 0.0
        rc = matched / len(r) if len(r) else 0.0
        per[c] = dict(precision=p, recall=rc, f1=2 * p * rc / (p + rc) if p + rc else 0.0, ref=len(r), est=len(e))
        tp_all += matched
        fp_all += len(e) - matched
        fn_all += len(r) - matched
    P = tp_all / (tp_all + fp_all) if tp_all + fp_all else 0
    R = tp_all / (tp_all + fn_all) if tp_all + fn_all else 0
    # Class accuracy among onset-matched hits, ignoring class during matching.
    rt = np.array([t for t, _ in ref])
    et = np.array([t for t, _ in est])
    correct = total = 0
    on_err = []
    if len(rt) and len(et):
        used = set()
        for j, (t, c) in enumerate(est):
            d = np.abs(rt - t)
            cands = [i for i in np.argsort(d)[:6] if d[i] <= TOL and i not in used]
            if not cands:
                continue
            same = [i for i in cands if ref[i][1] == c]
            i = same[0] if same else cands[0]
            used.add(i)
            total += 1
            correct += ref[i][1] == c
            on_err.append(abs(rt[i] - t) * 1000)
    return dict(precision=P, recall=R, f1=2 * P * R / (P + R) if P + R else 0.0,
                class_accuracy=correct / total if total else 0.0,
                onset_mae_ms=float(np.mean(on_err)) if on_err else None, per_class=per,
                ref_notes=len(ref), est_notes=len(est))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default="fast,balanced,high")
    ap.add_argument("--only", default="")
    ap.add_argument("--fixtures", default=str(ROOT / "fixtures"))
    ap.add_argument("--out", default=str(ROOT / "results"))
    args = ap.parse_args()
    fx = Path(args.fixtures)
    manifest = json.loads((fx / "manifest.json").read_text())
    only = [s for s in args.only.split(",") if s]
    results = {}
    for name, meta in manifest.items():
        if only and name not in only:
            continue
        pm = pretty_midi.PrettyMIDI(str(fx / f"{name}.mid"))
        audio = fx / f"{name}.flac"
        y, sr = audio_io.load(audio)
        tr = tempo.estimate([tempo.onset_envelopes(y, sr)])
        entry = {"class": meta["class"], "renderer": meta["renderer"], "true_bpm": meta["bpm"],
                 "estimated_bpm": round(tr.bpm, 2), "bpm_error": round(tr.bpm - meta["bpm"], 3), "modes": {}}
        for mode in args.modes.split(","):
            t0 = time.time()
            res = transcribe_file(str(audio), meta["class"], Options(mode=mode))
            dt = time.time() - t0
            if meta["class"] == "drums":
                ref = [(n.start, GM_TO_CLASS.get(n.pitch, "perc")) for i in pm.instruments for n in i.notes]
                est = [(n.start, n.drum) for n in res.notes]
                sc = drum_scores(ref, est)
            else:
                ref = [(n.start, n.end, n.pitch) for i in pm.instruments for n in i.notes]
                est = [(n.start, n.end, n.pitch) for n in res.notes]
                sc = melodic_scores(sorted(ref), sorted(est))
            sc["seconds"] = round(dt, 2)
            sc["engine"] = res.engine
            entry["modes"][mode] = sc
            print(f"{name:14s} {mode:8s} F1 {sc['f1']:.3f} P {sc['precision']:.3f} R {sc['recall']:.3f}"
                  + (f" class {sc['class_accuracy']:.3f}" if 'class_accuracy' in sc else f" F1+off {sc['f1_offset']:.3f} pitch {sc['pitch_acc']:.3f}")
                  + f" onsetMAE {sc['onset_mae_ms'] or 0:.1f}ms  {dt:.1f}s  [{res.engine}]", flush=True)
        results[name] = entry
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps(results, indent=2, default=float) + "\n")


if __name__ == "__main__":
    main()
