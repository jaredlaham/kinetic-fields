"""Harp Strings — each row is a string. Tap a pad to pluck that string at
that point: the vibration rings along the row and slowly dies away, and with
Sound on each string plays its note. Drag down a column (or press several
rows) to strum. Auto Strum plays gentle arpeggios when idle.

Each string is modelled as a sum of standing-wave modes (an ideal plucked
string), so plucking near the end rings brighter than plucking the middle.
"""

from __future__ import annotations

import math

from apc_light import audio
from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, IntParam

from ._kit import RETRO, WHITE, Canvas, is_pad_event, lane_note, mix

MODES = 6
L = 9.0            # string length in pad units (pads sit at 1..8, ends are fixed)


class HarpStrings(Effect):
    name = "Harp Strings"
    category = "Interactive"
    description = "Each row is a string: tap to pluck, drag to strum"
    fps = 50
    accepts_touch = True
    fader_param = "sustain"
    hint = "Tap a pad to pluck its row; press down a column to strum. Master fader = sustain."
    params = [
        IntParam("sustain", "Sustain", 5, 1, 10, ends=("Short", "Long")),
        ChoiceParam("scale", "Scale", ["Pentatonic", "Minor", "Major"], "Pentatonic"),
        BoolParam("sound", "Sound", False),
        BoolParam("auto", "Auto strum", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.plucks = []          # [row, pos, t0, amp]
        self.idle = 2.0
        self.auto_i = 0
        self.auto_next = 0.0
        self._sound_used = False

    def pluck(self, ctx, row, x, amp=1.0):
        self.plucks.append([row, x + 1.0, ctx.now, amp])
        del self.plucks[:-24]
        if ctx.params["sound"] and not ctx.preview:
            self._sound_used = True
            dur = 0.4 + ctx.params["sustain"] * 0.25
            audio.synth().play(audio.midi_to_hz(lane_note(row, ctx.params["scale"], 60)), dur, "triangle", 0.1 * amp)

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if event.pressed:
                self.pluck(ctx, event.y, event.x, 0.5 + 0.5 * event.velocity / 127.0)
                self.idle = 0.0
            return False
        return super().on_input(ctx, event)

    def update(self, ctx, frame):
        dt = min(ctx.real_dt, 0.1)
        p = ctx.params
        self.idle += dt
        if p["auto"] and self.idle > 3.0 and ctx.now >= self.auto_next:
            seq = (7, 5, 3, 1, 6, 4, 2, 0)
            row = seq[self.auto_i % 8]
            self.pluck(ctx, row, 2 + (self.auto_i * 3) % 4, 0.55)
            self.auto_i += 1
            self.auto_next = ctx.now + 0.32
        decay = 3.2 / p["sustain"]
        disp = [[0.0] * 8 for _ in range(8)]
        alive = []
        for row, pos, t0, amp in self.plucks:
            age = ctx.now - t0
            env = amp * math.exp(-age * decay)
            if env < 0.02:
                continue
            alive.append([row, pos, t0, amp])
            w0 = 9.0 + (7 - row) * 1.1           # higher strings vibrate faster
            for n in range(1, MODES + 1):
                # ideal plucked string: mode amplitude ~ sin(n*pi*p/L) / n^2
                a = math.sin(n * math.pi * pos / L) / (n * n) * env * 2.2
                osc = math.cos(w0 * n * age) * math.exp(-age * decay * (n - 1) * 0.6)
                for x in range(8):
                    disp[row][x] += a * osc * math.sin(n * math.pi * (x + 1) / L)
        self.plucks = alive
        c = self.canvas
        for y in range(8):
            base = RETRO(y / 8.0 + 0.02)
            for x in range(8):
                v = min(1.0, abs(disp[y][x]))
                c.set(y * 8 + x, base, 0.07)
                c.screen(y * 8 + x, mix(base, WHITE, max(0.0, v - 0.7)), v)
        c.to_frame(frame)

    def cleanup(self):
        if getattr(self, "_sound_used", False):
            audio.synth().close()
