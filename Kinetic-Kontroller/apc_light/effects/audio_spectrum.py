"""Audio Spectrum — an 8-band spectrum analyser on the pads.

Source "Microphone" listens to the Mac's current input device (macOS asks
for microphone permission once). To show music playing on the Mac, route it
through a loopback device such as BlackHole and pick that as the input in
System Settings > Sound. If no input is available, or it stays silent, the
effect plays a built-in demo groove instead so the pads never just sit dark.
Tap a column to punch that band; the scene buttons flash on the beat.
"""

from __future__ import annotations

import math
import os

from apc_light import audio
from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, IntParam

from ._kit import RETRO, WHITE, Canvas, is_pad_event, mix

SILENCE_FALLBACK = 2.5   # seconds of silence before the demo groove takes over


class AudioSpectrum(Effect):
    name = "Audio Spectrum"
    category = "Animated"
    description = "8-band spectrum analyser driven by the microphone (or a demo groove)"
    fps = 50
    accepts_touch = True
    fader_param = "gain"
    hint = ("Listens to the Mac's input device. For music on the Mac, route it through BlackHole. "
            "Falls back to a demo groove when there's no signal. Master fader = gain.")
    params = [
        ChoiceParam("source", "Source", ["Microphone", "Demo"], "Microphone"),
        IntParam("gain", "Gain", 5, 1, 10, ends=("Low", "High")),
        BoolParam("beat_flash", "Beat flash", True),
        BoolParam("peaks", "Peak hold", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.levels = [0.0] * 8
        self.peaks = [0.0] * 8
        self.peak_t = [0.0] * 8
        self.punch = [0.0] * 8
        self.beat = 0.0
        self.beat_seen = 0
        self.demo_beat = -1
        self.mic = None
        self.status = ""

    def _mic(self):
        if self.mic is None:
            self.mic = audio.analyzer()
            # never prompt for the microphone during the automated self-test
            if not os.environ.get("KK_NO_MIC"):
                self.mic.start()
        return self.mic

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if event.pressed:
                self.punch[event.x] = 1.0
            return False
        return super().on_input(ctx, event)

    def _demo(self, ctx):
        t = ctx.t
        bpm = 118.0
        beat_pos = t * bpm / 60.0
        k = beat_pos % 1.0
        kick = math.exp(-k * 7.0)
        hat = math.exp(-((beat_pos * 2) % 1.0) * 10.0)
        out = []
        for b in range(8):
            u = b / 7.0
            v = (kick * (1.0 - u) ** 1.6 * 0.95
                 + hat * u ** 2 * 0.7
                 + 0.32 + 0.22 * math.sin(t * (1.3 + b * 0.47) + b * 1.7)
                 * math.sin(t * 0.31 + b))
            out.append(max(0.0, min(1.0, v)))
        if int(beat_pos) != self.demo_beat:
            self.demo_beat = int(beat_pos)
            self.beat = 1.0
        return out

    def update(self, ctx, frame):
        dt = min(ctx.real_dt, 0.1)
        p = ctx.params
        bands = None
        if p["source"] == "Microphone" and not ctx.preview:
            mic = self._mic()
            live = mic.available and ctx.now - mic.last_audio < SILENCE_FALLBACK
            if live:
                gain = 0.4 + p["gain"] * 0.16
                bands = [min(1.0, v * gain) for v in mic.bands]
                if mic.beats != self.beat_seen:
                    self.beat_seen = mic.beats
                    self.beat = 1.0
            self.status = "live" if live else (mic.error or "silent")
        elif self.mic is not None:
            self.mic.close()
            self.mic = None
        if bands is None:
            bands = self._demo(ctx)
        for b in range(8):
            v = max(bands[b], self.punch[b])
            # fast attack, smooth release
            self.levels[b] = v if v > self.levels[b] else self.levels[b] + (v - self.levels[b]) * min(1.0, dt * 9)
            if self.levels[b] >= self.peaks[b]:
                self.peaks[b], self.peak_t[b] = self.levels[b], ctx.now
            elif ctx.now - self.peak_t[b] > 0.5:
                self.peaks[b] = max(0.0, self.peaks[b] - dt * 0.9)
            self.punch[b] = max(0.0, self.punch[b] - dt * 3.0)
        self.beat = max(0.0, self.beat - dt * 5.0)
        self._draw(ctx, frame)

    def _draw(self, ctx, frame):
        c = self.canvas
        c.clear()
        p = ctx.params
        for x in range(8):
            h = self.levels[x] * 8.0
            for row in range(8):          # row 0 = bottom
                y = 7 - row
                fill = max(0.0, min(1.0, h - row))
                if fill > 0:
                    col = RETRO(0.02 + row * 0.075)
                    c.set(y * 8 + x, col, 0.25 + 0.75 * fill)
            if p["peaks"] and self.peaks[x] > 0.06:
                pr = min(7, int(self.peaks[x] * 8.0 - 0.001))
                c.screen((7 - pr) * 8 + x, WHITE, 0.85)
        if p["beat_flash"] and self.beat > 0:
            for i in range(56, 64):
                c.screen(i, mix((1.0, 0.4, 0.2), WHITE, 0.3), self.beat * 0.5)
        c.to_frame(frame)

    def scene_leds(self, ctx):
        if not ctx.params["beat_flash"]:
            return None
        return [1 if self.beat > 0.4 else 0] * 8

    def cleanup(self):
        if self.mic is not None:
            self.mic.close()
            self.mic = None
