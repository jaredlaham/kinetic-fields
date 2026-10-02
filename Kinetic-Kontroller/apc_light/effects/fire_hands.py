"""Fire Hands — hold pads and flames rise from your fingers.

A small heat simulation runs on a 8×10 grid (two hidden rows above the top
so flames can lick off the edge). Every held pad is a heat source; harder
presses burn hotter. Release and the fire dies down to embers.
"""

from __future__ import annotations

import random

from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, IntParam

from ._kit import Canvas, is_pad_event, mix

PALETTES = {
    "Classic": ((0.0, 0.0, 0.0), (0.75, 0.05, 0.0), (1.0, 0.45, 0.0), (1.0, 0.85, 0.25), (1.0, 1.0, 0.85)),
    "Blue": ((0.0, 0.0, 0.0), (0.05, 0.05, 0.6), (0.0, 0.45, 1.0), (0.3, 0.85, 1.0), (0.9, 1.0, 1.0)),
    "Green": ((0.0, 0.0, 0.0), (0.0, 0.35, 0.05), (0.15, 0.8, 0.1), (0.7, 1.0, 0.3), (1.0, 1.0, 0.85)),
    "Purple": ((0.0, 0.0, 0.0), (0.35, 0.0, 0.5), (0.75, 0.15, 0.9), (1.0, 0.5, 0.95), (1.0, 0.9, 1.0)),
}
H = 10           # simulated rows (row 0..1 are above the grid)
TICK = 1 / 30.0


def heat_colour(pal, h):
    h = max(0.0, min(1.0, h)) * (len(pal) - 1)
    i = min(int(h), len(pal) - 2)
    return mix(pal[i], pal[i + 1], h - i)


class FireHands(Effect):
    name = "Fire Hands"
    category = "Interactive"
    description = "Hold pads and flames rise from your fingers"
    fps = 50
    accepts_touch = True
    fader_param = "height"
    hint = "Hold pads to burn; harder presses burn hotter. Master fader = flame height."
    params = [
        IntParam("height", "Flame height", 6, 1, 10, ends=("Low", "Tall")),
        ChoiceParam("palette", "Palette", list(PALETTES), "Classic"),
        BoolParam("embers", "Idle embers", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.rng = random.Random()
        self.heat = [[0.0] * 8 for _ in range(H)]
        self.acc = 0.0
        self.flare = {}     # (x, y) -> extra heat from a fresh press

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if event.pressed:
                self.flare[(event.x, event.y)] = 0.6 + 0.6 * event.velocity / 127.0
            return False
        return super().on_input(ctx, event)

    def _step(self, ctx):
        rng = self.rng
        heat = self.heat
        cool = 0.30 - ctx.params["height"] * 0.022       # taller flames cool more slowly
        held = ctx.interaction.held if ctx.interaction is not None else {}
        for (x, y), ev in held.items():
            heat[y + 2][x] = min(1.4, heat[y + 2][x] + 0.55 + 0.4 * ev.velocity / 127.0)
        for (x, y), k in list(self.flare.items()):
            heat[y + 2][x] = min(1.6, heat[y + 2][x] + k)
            self.flare[(x, y)] = k * 0.5
            if k < 0.05:
                del self.flare[(x, y)]
        if ctx.params["embers"]:
            for x in range(8):
                if rng.random() < 0.12:
                    heat[H - 1][x] = max(heat[H - 1][x], 0.25 + rng.random() * 0.3)
        new = [[0.0] * 8 for _ in range(H)]
        for y in range(H - 1):
            for x in range(8):
                below = heat[y + 1]
                side = (below[(x - 1) % 8] + below[(x + 1) % 8]) * 0.5
                v = below[x] * 0.62 + side * 0.25 + heat[y][x] * 0.18
                v -= cool * (0.5 + rng.random())
                new[y][x] = max(0.0, v)
        for x in range(8):
            new[H - 1][x] = heat[H - 1][x] * 0.55
        for (x, y) in held:
            new[y + 2][x] = max(new[y + 2][x], heat[y + 2][x] * 0.9)
        self.heat = new

    def update(self, ctx, frame):
        self.acc += min(ctx.dt, 0.1)
        while self.acc >= TICK:
            self.acc -= TICK
            self._step(ctx)
        pal = PALETTES.get(ctx.params["palette"], PALETTES["Classic"])
        c = self.canvas
        for y in range(8):
            row = self.heat[y + 2]
            for x in range(8):
                c.set(y * 8 + x, heat_colour(pal, row[x]))
        c.to_frame(frame)
