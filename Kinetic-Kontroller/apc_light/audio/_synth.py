"""Tiny polyphonic synth (sine / triangle plucks) for effects with a Sound
toggle. One PortAudio output stream, opened on first note, closed by the
effect's cleanup."""

from __future__ import annotations

import logging
import math
import threading
from typing import List

log = logging.getLogger("apc.audio")

RATE = 44100


class Synth:
    def __init__(self) -> None:
        self.available = True
        self.error = ""
        self._voices: List[list] = []    # [freq, t, dur, wave, vol]
        self._lock = threading.Lock()
        self._stream = None
        self._np = None

    def _ensure(self) -> bool:
        if self._stream is not None:
            return True
        if not self.available:
            return False
        try:
            import numpy as np
            import sounddevice as sd

            self._np = np
            self._stream = sd.OutputStream(samplerate=RATE, channels=1, blocksize=256, dtype="float32",
                                           callback=self._callback)
            self._stream.start()
            log.info("Synth output started")
            return True
        except Exception as exc:
            self.available = False
            self.error = f"audio output unavailable ({exc})"
            log.warning(self.error)
            self._stream = None
            return False

    def play(self, freq: float, dur: float = 0.5, wave: str = "triangle", vol: float = 0.18) -> None:
        if not self._ensure():
            return
        with self._lock:
            self._voices.append([float(freq), 0.0, float(dur), wave, float(vol)])
            del self._voices[:-24]

    def _callback(self, outdata, frames, _time, _status) -> None:
        np = self._np
        buf = np.zeros(frames, dtype="float32")
        t_local = np.arange(frames, dtype="float32") / RATE
        with self._lock:
            alive = []
            for v in self._voices:
                freq, t0, dur, wave, vol = v
                t = t0 + t_local
                env = np.minimum(1.0, t / 0.004) * np.exp(-t * 5.0 / dur)
                ph = 2.0 * math.pi * freq * t
                osc = np.sin(ph) if wave == "sine" else (2.0 / math.pi) * np.arcsin(np.sin(ph))
                buf += (osc * env * vol).astype("float32")
                v[1] = t0 + frames / RATE
                if v[1] < dur * 1.6:
                    alive.append(v)
            self._voices = alive
        outdata[:, 0] = np.tanh(buf)

    def silence(self) -> None:
        with self._lock:
            self._voices = []

    def close(self) -> None:
        self.silence()
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            finally:
                self._stream = None
                log.info("Synth output stopped")

