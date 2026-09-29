"""Heart — a heart icon (port of apc_heart.sh), optionally beating."""

import math

from apc_light.engine.effect import BoolParam, ColorParam, Effect
from apc_light.engine.frame import scale, to_rgb

HEART = [
    ".XX..XX.",
    "XXXXXXXX",
    "XXXXXXXX",
    "XXXXXXXX",
    ".XXXXXX.",
    "..XXXX..",
    "...XX...",
    "........",
]


class Heart(Effect):
    name = "Heart"
    category = "Static"
    description = "A heart; turn on Beat for a heartbeat pulse"
    animated = False
    shortcut = "4"
    order = 20
    params = [
        ColorParam("color", "Color", "#ff0000"),
        ColorParam("background", "Background", "#000000"),
        BoolParam("beat", "Beat", False),
    ]

    def is_animated(self, params):
        return bool(params.get("beat"))

    def update(self, ctx, frame):
        color = to_rgb(ctx.params["color"])
        if ctx.params["beat"]:
            # "lub-dub": two quick pulses per ~1.1 s cycle.
            p = (ctx.t / 1.1) % 1.0
            k = max(math.exp(-((p - 0.05) / 0.06) ** 2), 0.8 * math.exp(-((p - 0.28) / 0.07) ** 2))
            color = scale(color, 0.25 + 0.75 * k)
        frame.fill(ctx.params["background"])
        frame.draw_bitmap(HEART, {"X": color})
