"""Kaleidoscope Paint — whatever you touch is mirrored 4 or 8 ways around
the centre of the grid and slowly fades, so a few taps become a mandala.
Hold and drag across pads to paint strokes. With Auto Draw on, an invisible
brush wanders on its own when nobody is playing."""

from __future__ import annotations

import math

from apc_light.engine.compositor import hexf
from apc_light.engine.effect import BoolParam, ChoiceParam, ColorParam, Effect, IntParam

from ._kit import RETRO, Canvas, is_pad_event


def mirrors(x, y, mode):
    pts = {(x, y), (7 - x, y), (x, 7 - y), (7 - x, 7 - y)}
    if mode == "8-way":
        pts |= {(y, x), (7 - y, x), (y, 7 - x), (7 - y, 7 - x)}
    return pts


class KaleidoscopePaint(Effect):
    name = "Kaleidoscope Paint"
    category = "Interactive"
    description = "Every touch is mirrored around the centre into a fading mandala"
    fps = 50
    accepts_touch = True
    fader_param = "trail"
    hint = "Tap or hold pads to paint; each touch is mirrored. Master fader = how long the paint lasts."
    params = [
        ChoiceParam("symmetry", "Symmetry", ["4-way", "8-way"], "8-way"),
        IntParam("trail", "Trail", 5, 1, 10, ends=("Short", "Long")),
        ChoiceParam("colour", "Colour", ["Retro drift", "Single colour"], "Retro drift"),
        ColorParam("color", "Paint colour", "#00b5b8"),
        BoolParam("auto", "Auto draw", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.paint = [[0.0, 0.0, 0.0] for _ in range(64)]
        self.idle = 3.0
        self.bx, self.by = 3.0, 1.0

    def _colour(self, ctx):
        if ctx.params["colour"] == "Single colour":
            return hexf(ctx.params["color"])
        return RETRO(ctx.now * 0.07)

    def _dab(self, ctx, x, y, k=1.0):
        col = self._colour(ctx)
        for mx, my in mirrors(x, y, ctx.params["symmetry"]):
            cell = self.paint[my * 8 + mx]
            for j in range(3):
                cell[j] = min(1.0, cell[j] * (1 - k) + col[j] * k + cell[j] * k * 0.3)

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if event.pressed:
                self._dab(ctx, event.x, event.y)
                self.idle = 0.0
            return False
        return super().on_input(ctx, event)

    def update(self, ctx, frame):
        dt = min(ctx.real_dt, 0.1)
        held = ctx.interaction.held if ctx.interaction is not None else {}
        for (x, y) in list(held):
            self._dab(ctx, x, y, min(1.0, dt * 6))
        if held:
            self.idle = 0.0
        else:
            self.idle += dt
        if ctx.params["auto"] and self.idle > 2.5:
            t = ctx.t * 0.6
            self.bx = 3.5 + 3.4 * math.sin(t * 1.3) * math.cos(t * 0.37)
            self.by = 3.5 + 3.4 * math.sin(t * 0.9 + 1.1)
            self._dab(ctx, int(round(self.bx)), int(round(self.by)), min(1.0, dt * 3))
        fade = math.exp(-dt * (2.4 / ctx.params["trail"]))
        c = self.canvas
        for i, cell in enumerate(self.paint):
            cell[0] *= fade
            cell[1] *= fade
            cell[2] *= fade
            c.set(i, cell)
        c.to_frame(frame)
