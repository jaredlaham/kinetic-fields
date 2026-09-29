"""Mosaic — tiles of colour that keep re-arranging (port of apc_mosaic.sh)."""

from apc_light.engine.effect import ChoiceParam, ColorParam, Effect, IntParam
from apc_light.engine.frame import hsv, lerp, to_rgb

PALETTES = {
    "Rainbow": None,
    "Warm": ["#ff0000", "#ff5400", "#ffbd00", "#ff0054", "#ff4c4c"],
    "Cool": ["#0055ff", "#00a9ff", "#00ff99", "#5400ff", "#4cc3ff"],
    "Neon": ["#ff00ff", "#00ffff", "#54ff00", "#ffff00", "#ff0054"],
}


class Mosaic(Effect):
    name = "Mosaic"
    category = "Animated"
    description = "Colour tiles re-arranging themselves"
    shortcut = "3"
    order = 35
    params = [
        ChoiceParam("palette", "Palette", list(PALETTES) + ["Single colour"]),
        ColorParam("color", "Colour", "#00a9ff"),
        IntParam("tile", "Tile size", 2, 1, 4),
    ]

    def start(self, ctx):
        self._step = -1

    def _pick(self, ctx):
        name = ctx.params["palette"]
        if name == "Single colour":
            base = to_rgb(ctx.params["color"])
            return lerp(base, (0, 0, 0), ctx.rng.choice((0.0, 0.0, 0.4, 0.7, 1.0)))
        pal = PALETTES.get(name)
        if pal is None:
            return hsv(ctx.rng.random())
        return to_rgb(ctx.rng.choice(pal))

    def update(self, ctx, frame):
        step = ctx.step(0.18)
        tile = int(ctx.params["tile"])
        if self._step < 0:  # fill completely on the first frame
            for ty in range(0, 8, tile):
                for tx in range(0, 8, tile):
                    self._tile(frame, tx, ty, tile, self._pick(ctx))
            self._step = step
            return
        while self._step < step:  # one tile per step, catching up if needed
            self._step += 1
            tx = ctx.rng.randrange(0, 8, tile)
            ty = ctx.rng.randrange(0, 8, tile)
            self._tile(frame, tx, ty, tile, self._pick(ctx))

    @staticmethod
    def _tile(frame, tx, ty, size, color):
        for y in range(ty, min(8, ty + size)):
            for x in range(tx, min(8, tx + size)):
                frame.set(x, y, color)
