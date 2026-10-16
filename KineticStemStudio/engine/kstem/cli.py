"""Engine command line, used by the macOS app as a worker process.

    python -m kstem <command> < request.json

The request is one JSON object on stdin. Output is JSON Lines on stdout:
    {"event": "progress", "fraction": 0.42, "message": "..."}
    {"event": "result", "data": {...}}
    {"event": "error", "message": "...", "kind": "..."}
Diagnostics go to stderr. The process exits 0 after a result and 1 after an
error. The app cancels a job by terminating the process; nothing is written
in place, so a cancelled job leaves no partial output.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
import traceback

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
logging.basicConfig(stream=sys.stderr, level=logging.WARNING, format="kstem %(levelname)s %(message)s")

from . import __version__  # noqa: E402

_OUT = sys.stdout


def emit(obj: dict) -> None:
    _OUT.write(json.dumps(obj, default=float) + "\n")
    _OUT.flush()


def progress(fraction: float, message: str) -> None:
    emit({"event": "progress", "fraction": round(max(0.0, min(1.0, fraction)), 4), "message": message})


def cmd_version(req):
    return {"version": __version__, "python": sys.version.split()[0]}


def cmd_doctor(req):
    checks = []

    def check(name, fn, required=True):
        t = time.time()
        try:
            detail = fn()
            checks.append({"name": name, "ok": True, "detail": detail or "", "required": required,
                           "ms": round((time.time() - t) * 1000)})
        except Exception as e:
            checks.append({"name": name, "ok": False, "detail": str(e)[:300], "required": required})

    check("numpy / scipy", lambda: __import__("numpy").__version__ + " / " + __import__("scipy").__version__)
    check("librosa", lambda: __import__("librosa").__version__)
    check("soundfile (libsndfile)", lambda: __import__("soundfile").__libsndfile_version__)
    check("mido", lambda: __import__("importlib.metadata").metadata.version("mido"))
    check("onnxruntime", lambda: __import__("onnxruntime").__version__ + " providers " + ",".join(__import__("onnxruntime").get_available_providers()))

    def bp():
        from . import poly

        ok, msg = poly.available()
        if not ok:
            raise RuntimeError(msg)
        return msg

    check("Basic Pitch model", bp)

    def drum():
        from . import drums

        drums._model()
        return str(drums.MODEL_PATH.name)

    check("Drum hit classifier", drum)

    def ff():
        import shutil

        p = shutil.which("ffmpeg")
        if not p:
            raise RuntimeError("not found (needed only for formats libsndfile cannot read, e.g. M4A)")
        return p

    check("ffmpeg", ff, required=False)

    def crepe():
        import torchcrepe  # noqa: F401
        import torch

        return f"torch {torch.__version__}, MPS {'available' if torch.backends.mps.is_available() else 'not available'}"

    check("CREPE (optional, High Accuracy melodic)", crepe, required=False)
    return {"version": __version__, "checks": checks, "ok": all(c["ok"] for c in checks if c["required"])}


def cmd_analyze(req):
    """Per-stem metadata and instrument proposal, plus one shared tempo grid."""
    import numpy as np

    from . import audio_io, classify, tempo

    files = req["files"]
    beats_per_bar = int(req.get("beats_per_bar", 4))
    stems_out = []
    envs = []
    signals = []
    n = len(files)
    for k, f in enumerate(files):
        base = k / n
        progress(base, f"Reading {os.path.basename(f['path'])}")
        info = audio_io.info(f["path"])
        y, sr = audio_io.load(f["path"], sr=tempo.SR)
        entry = {"id": f.get("id"), "path": f["path"], "sha256": audio_io.file_hash(f["path"]),
                 "sample_rate": info.sample_rate, "channels": info.channels, "frames": info.frames,
                 "duration": round(info.duration, 4), "format": info.format,
                 "leading_silence": round(audio_io.leading_silence(y, sr), 4),
                 "peak_dbfs": round(float(20 * np.log10(np.max(np.abs(y)) + 1e-9)), 2)}
        progress(base + 0.3 / n, f"Finding the beat in {os.path.basename(f['path'])}")
        envs.append(tempo.onset_envelopes(y, sr))
        signals.append((y, sr))
        if req.get("classify", True):
            progress(base + 0.5 / n, f"Identifying the instrument in {os.path.basename(f['path'])}")
            try:
                polyphony, median = classify.note_features(y, sr)
            except Exception as e:  # Basic Pitch missing: classify without note statistics
                logging.warning("note statistics unavailable: %s", e)
                polyphony, median = None, None
            entry["classification"] = classify.classify(classify.features(y, sr, polyphony, median)).to_json()
        stems_out.append(entry)
    progress(0.95, "Estimating a shared tempo grid")
    grid = tempo.estimate(envs, beats_per_bar=beats_per_bar)
    grid.beats, shift = tempo.refine_phase(grid.beats, signals)
    grid.downbeat += shift
    return {"stems": stems_out, "tempo": grid.to_json()}


def cmd_transcribe(req):
    from .transcribe import Options, transcribe_file

    opts = Options(mode=req.get("mode", "balanced"), pitch_bends=bool(req.get("pitch_bends", False)),
                   allow_crepe=bool(req.get("allow_crepe", True)), drum_sensitivity=float(req.get("sensitivity", 0.5)))
    res = transcribe_file(req["path"], req["instrument"], opts, progress=progress)
    out = res.to_json()
    from .audio_io import file_hash

    out["audio_sha256"] = file_hash(req["path"])
    return out


def _track(t):
    from .export.smf import TrackIn

    return TrackIn(name=t["name"], channel=int(t.get("channel", 1)), notes=t["notes"], program=t.get("program"),
                   is_drum=bool(t.get("is_drum", False)))


def cmd_export_midi(req):
    from .export import smf

    region = tuple(req["region"]) if req.get("region") else None
    rep = smf.export([_track(t) for t in req["tracks"]], float(req["bpm"]), tuple(req.get("meter", [4, 4])),
                     int(req.get("tpq", 480)), req["out"], req.get("layout", "multitrack"), req.get("title", "Kinetic Stem"),
                     region)
    return rep.to_json()


def cmd_export_ableton(req):
    from .export import ableton

    stems = [ableton.StemIn(name=s["name"], path=s.get("path"), instrument=s.get("instrument", "other_melodic"),
                            midi=_track(s["midi"]) if s.get("midi") else None,
                            include_audio=bool(s.get("include_audio", True))) for s in req["stems"]]
    progress(0.2, "Writing the project folder")
    rep = ableton.export(stems, float(req["bpm"]), tuple(req.get("meter", [4, 4])), req["title"], req["parent"],
                         req.get("kind", "native"), int(req.get("tpq", 480)), bool(req.get("overwrite", False)))
    return rep.to_json()


def cmd_t8_convert(req):
    from .export import t8

    conv = t8.convert(req.get("drum_notes", []), req.get("bass_notes", []), float(req["bpm"]),
                      float(req.get("grid_start", 0.0)), int(req.get("steps", 16)), req.get("segments"),
                      req.get("drum_map"))
    out = conv.to_json()
    if req.get("midi_out"):
        out["midi_file"] = t8.to_midi(conv, req["midi_out"], int(req.get("rhythm_channel", 10)),
                                      int(req.get("bass_channel", 2)))
    return out


COMMANDS = {
    "version": cmd_version, "doctor": cmd_doctor, "analyze": cmd_analyze, "transcribe": cmd_transcribe,
    "export-midi": cmd_export_midi, "export-ableton": cmd_export_ableton, "t8-convert": cmd_t8_convert,
}


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] not in COMMANDS:
        sys.stderr.write("usage: python -m kstem {" + ",".join(COMMANDS) + "} < request.json\n")
        return 2
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        req = json.loads(raw) if raw.strip() else {}
        emit({"event": "result", "data": COMMANDS[argv[0]](req)})
        return 0
    except FileExistsError as e:
        emit({"event": "error", "kind": "exists", "message": str(e)})
    except FileNotFoundError as e:
        emit({"event": "error", "kind": "not_found", "message": str(e)})
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        emit({"event": "error", "kind": type(e).__name__, "message": str(e)})
    return 1
