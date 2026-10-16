"""Audio decoding. Source files are only ever read, never written."""
from __future__ import annotations

import hashlib
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf

SUPPORTED = {".wav", ".wave", ".mp3", ".aif", ".aiff", ".flac", ".m4a", ".caf", ".ogg"}


class AudioError(RuntimeError):
    pass


@dataclass
class AudioInfo:
    path: str
    sample_rate: int
    channels: int
    frames: int
    duration: float
    format: str


def file_hash(path: str | Path, chunk: int = 1 << 20) -> str:
    """SHA-256 of the file bytes; the cache key for analysis and transcription."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def info(path: str | Path) -> AudioInfo:
    path = Path(path)
    try:
        i = sf.info(str(path))
        return AudioInfo(str(path), int(i.samplerate), int(i.channels), int(i.frames), float(i.duration), i.format)
    except Exception:
        y, sr = load(path, sr=None, mono=False)
        frames = y.shape[-1]
        return AudioInfo(str(path), sr, 1 if y.ndim == 1 else y.shape[0], frames, frames / sr, path.suffix.lstrip(".").upper())


def _ffmpeg_decode(path: Path, sr: int | None) -> tuple[np.ndarray, int]:
    exe = shutil.which("ffmpeg")
    if not exe:
        raise AudioError(f"Cannot decode {path.name}: libsndfile does not read this format and ffmpeg is not installed.")
    rate = sr or 44100
    cmd = [exe, "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-ac", "2", "-ar", str(rate), "-"]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        raise AudioError(f"ffmpeg could not decode {path.name}: {proc.stderr.decode(errors='replace').strip()[:300]}")
    data = np.frombuffer(proc.stdout, dtype=np.float32).reshape(-1, 2).T
    return data, rate


def load(path: str | Path, sr: int | None = 22050, mono: bool = True) -> tuple[np.ndarray, int]:
    """Decode to float32. Returns (samples, sample_rate); samples are (n,) when mono else (ch, n)."""
    path = Path(path)
    if not path.exists():
        raise AudioError(f"File not found: {path}")
    try:
        data, rate = sf.read(str(path), dtype="float32", always_2d=True)
        data = data.T
    except Exception:
        data, rate = _ffmpeg_decode(path, sr)
    if mono:
        data = data.mean(axis=0)
    if sr is not None and rate != sr:
        import librosa

        data = librosa.resample(data, orig_sr=rate, target_sr=sr, res_type="soxr_hq")
        rate = sr
    return np.ascontiguousarray(data, dtype=np.float32), int(rate)


def leading_silence(y: np.ndarray, sr: int, threshold_db: float = -50.0) -> float:
    """Seconds before the signal first rises above threshold_db (relative to full scale)."""
    if y.size == 0:
        return 0.0
    hop = 256
    frames = len(y) // hop
    if frames == 0:
        return 0.0
    rms = np.sqrt(np.mean(y[: frames * hop].reshape(frames, hop) ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(rms)
    above = np.nonzero(db > threshold_db)[0]
    return float(above[0] * hop / sr) if above.size else float(len(y) / sr)
