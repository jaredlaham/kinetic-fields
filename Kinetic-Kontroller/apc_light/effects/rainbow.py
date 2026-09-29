"""Rainbow — rainbow stripes that drift through the spectrum
(port of apc_rainbow_simple.sh)."""

from apc_light.engine.effect import ChoiceParam, Effect
from apc_light.engine.frame import hsv


class Rainbow(Effect):
    name = "Rainbow"
    category = "Animated"
    description = "Rainbow stripes cycling through the spectrum"
    shortcut = "1"
    order = 10
    params = [ChoiceParam("layout", "Layout", ["Columns", "Rows", "Whole grid"])]

    def update(self, ctx, frame):
        layout = ctx.params["layout"]
        base = ctx.t * 0.15
        for x, y in frame.coords():
            if layout == "Columns":
                h = base + x / 8
            elif layout == "Rows":
                h = base + y / 8
            else:
                h = base
            frame.set(x, y, hsv(h))
