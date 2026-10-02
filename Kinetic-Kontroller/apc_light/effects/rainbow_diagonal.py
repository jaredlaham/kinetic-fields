"""Diagonal Rainbow — rainbow bands sweeping diagonally
(port of apc_rainbow_diagonal_wave.sh)."""

from apc_light.engine.effect import ChoiceParam, Effect
from apc_light.engine.frame import hsv


class DiagonalRainbow(Effect):
    name = "Diagonal Rainbow"
    category = "Animated"
    description = "Rainbow bands sweeping corner to corner"
    order = 30
    params = [ChoiceParam("band", "Band width", ["Narrow", "Medium", "Wide"], "Medium")]

    def update(self, ctx, frame):
        span = {"Narrow": 6.0, "Medium": 12.0, "Wide": 24.0}[ctx.params["band"]]
        for x, y in frame.coords():
            frame.set(x, y, hsv((x + (7 - y)) / span - ctx.t * 0.3))
