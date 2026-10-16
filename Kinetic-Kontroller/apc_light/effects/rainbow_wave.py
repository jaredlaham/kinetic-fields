"""Rainbow Wave — a horizontal rainbow that rolls across the grid with a
travelling brightness wave (port of apc_rainbow_wave.sh)."""

import math

from apc_light.engine.effect import ChoiceParam, Effect
from apc_light.engine.frame import hsv


class RainbowWave(Effect):
    name = "Rainbow Wave"
    category = "Animated"
    description = "Rainbow rolling left to right with a wave"
    order = 20
    params = [ChoiceParam("direction", "Direction", ["Left to right", "Right to left", "Up", "Down"])]

    def update(self, ctx, frame):
        d = ctx.params["direction"]
        t = ctx.t
        for x, y in frame.coords():
            if d == "Left to right":
                u, v = -x, y
            elif d == "Right to left":
                u, v = x, y
            elif d == "Up":
                u, v = y, x
            else:
                u, v = -y, x
            hue = u / 10 + t * 0.35
            wave = 0.5 + 0.5 * math.sin(u * 0.8 + v * 0.35 + t * 3.0)
            frame.set(x, y, hsv(hue, 1.0, 0.35 + 0.65 * wave))
