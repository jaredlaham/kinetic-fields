"""Creeper — the Minecraft creeper face (port of apc_creeper.sh)."""

from apc_light.engine.effect import BoolParam, ColorParam, Effect
from apc_light.engine.frame import lerp, to_rgb

FACE = [
    "GGGGGGGG",
    "GGGGGGGG",
    "GBBGGBBG",
    "GBBGGBBG",
    "GGGBBGGG",
    "GGBBBBGG",
    "GGBBBBGG",
    "GGBGGBGG",
]

# Skin texture: mixes of the base colour with lighter/darker greens.
_SHADES = (0.0, 0.0, 0.0, 0.35, 0.6)


class Creeper(Effect):
    name = "Creeper"
    category = "Animated"
    description = "Creeper face with a shimmering pixel skin"
    animated = True
    shortcut = "3"
    order = 40
    params = [
        ColorParam("color", "Skin", "#00ff00"),
        ColorParam("face", "Face", "#000000"),
        BoolParam("shimmer", "Shimmer", True),
    ]

    def is_animated(self, params):
        return bool(params.get("shimmer"))

    def start(self, ctx):
        self._last_step = -1

    def update(self, ctx, frame):
        skin = to_rgb(ctx.params["color"])
        face = to_rgb(ctx.params["face"])
        shimmer = ctx.params["shimmer"]
        step = ctx.step(0.35)
        if shimmer and step == self._last_step:
            return  # keep the texture until the next step
        self._last_step = step
        light = lerp(skin, (200, 255, 200), 0.6)
        dark = lerp(skin, (0, 0, 0), 0.6)
        for y, row in enumerate(FACE):
            for x, ch in enumerate(row):
                if ch == "B":
                    frame.set(x, y, face)
                elif shimmer:
                    r = ctx.rng.choice(_SHADES)
                    frame.set(x, y, lerp(skin, light if ctx.rng.random() < 0.5 else dark, r))
                else:
                    frame.set(x, y, skin)
