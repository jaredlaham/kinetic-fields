"""Microphone / input-device spectrum analyzer (8 log-spaced bands + beats).

Uses PortAudio through ``sounddevice``; analysis runs in the audio callback
with NumPy and publishes plain floats, so effects just read ``bands``.
macOS asks for microphone permission the first time the stream opens (the
app's Info.plist carries NSMicrophoneUsageDescription). To visualize music
playing on the Mac, route it through a loopback device (e.g. BlackHole) and
choose that as the input in System Settings > Sound.
"""

from __future__ import annotations

import logging
import math
import threading
import time
from typing import List

log = logging.getLogger("apc.audio")

BANDS = 8
F_LO, F_HI = 45.0, 14000.0


class AudioAnalyzer:
    def __init__(self) -> None:
        self.available = False
        self.error = ""
        self.bands: List[float] = [0.0] * BANDS     # 0..1, smoothed
        self.level = 0.0
        self.beats = 0                              # increments on each detected beat
        self.last_audio = 0.0                       # monotonic time of last non-silent block
        self._stream = None
        self._lock = threading.Lock()
        self._np = None
        self._edges = None
        self._win = None
        self._bass_avg = 0.0
        self._last_beat = 0.0

    @property
    def running(self) -> bool:
        return self._stream is not None

    def start(self) -> bool:
        with self._lock:
            if self._stream is not None:
                return True
            try:
                import numpy as np
                import sounddevice as sd
            except Exception as exc:  # missing PortAudio / NumPy
                self.error = f"audio input unavailable ({exc})"
                log.warning(self.error)
                return False
            try:
                rate = int(sd.query_devices(kind="input")["default_samplerate"]) or 44100
                n = 1024
                freqs = np.fft.rfftfreq(n, 1.0 / rate)
                edges = np.geomspace(F_LO, min(F_HI, rate / 2 - 1), BANDS + 1)
                self._edges = [(int(np.searchsorted(freqs, edges[i])), max(int(np.searchsorted(freqs, edges[i + 1])),
                                int(np.searchsorted(freqs, edges[i])) + 1)) for i in range(BANDS)]
                self._win = np.hanning(n).astype("float32")
                self._np = np
                self._stream = sd.InputStream(samplerate=rate, channels=1, blocksize=n, dtype="float32",
                                              callback=self._callback)
                self._stream.start()
                self.available = True
                self.error = ""
                log.info("Audio input started (%s Hz)", rate)
                return True
            except Exception as exc:
                self._stream = None
                self.error = f"could not open audio input ({exc})"
                log.warning(self.error)
                return False

    def _callback(self, indata, frames, _time, _status) -> None:
        np = self._np
        try:
            x = indata[:, 0]
            if len(x) != len(self._win):
                return
            rms = float(np.sqrt(np.mean(x * x)))
            if rms > 1e-4:
                self.last_audio = time.monotonic()
            spec = np.abs(np.fft.rfft(x * self._win))
            out = []
            for lo, hi in self._edges:
                e = float(np.mean(spec[lo:hi])) if hi > lo else 0.0
                db = 20.0 * math.log10(e + 1e-9)
                out.append(min(1.0, max(0.0, (db + 20.0) / 50.0)))   # ~-20..+30 dB -> 0..1
            bands = self.bands
            for i, v in enumerate(out):
                bands[i] = v if v > bands[i] else bands[i] * 0.82 + v * 0.18
            self.level = min(1.0, rms * 6.0)
            bass = (out[0] + out[1]) / 2
            now = time.monotonic()
            if bass > self._bass_avg * 1.35 + 0.08 and now - self._last_beat > 0.22:
                self.beats += 1
                self._last_beat = now
            self._bass_avg = self._bass_avg * 0.95 + bass * 0.05
        except Exception:
            pass

    def close(self) -> None:
        with self._lock:
            if self._stream is not None:
                try:
                    self._stream.stop()
                    self._stream.close()
                finally:
                    self._stream = None
                    log.info("Audio input stopped")
            self.bands = [0.0] * BANDS
