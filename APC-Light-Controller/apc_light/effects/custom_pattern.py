"""Custom Pattern — paint your own static image.

Click pads in the on-screen APC (or press pads on the hardware) to paint with
the Brush colour; right-click (or press a lit pad on the hardware) to erase.
The pattern is saved with your settings."""

from apc_light.engine.effect import ColorParam, Effect, Param

BLANK = ["#000000"] * 64


class PatternParam(Param):
    def coerce(self, value):
        if isinstance(value, list) and len(value) == 64 and all(isinstance(v, str) for v in value):
            return [ColorParam("_", "_").coerce(v) if v != "#000000" else v for v in value]
        return list(BLANK)


class CustomPattern(Effect):
    name = "Custom Pattern"
    category = "Static"
    description = "Paint pads on the on-screen APC to draw your own pattern"
    animated = False
    order = 30
    params = [
        ColorParam("brush", "Brush", "#ff00ff"),
        PatternParam("pattern", "Pattern", "pattern", list(BLANK), hidden=True),
    ]

    def update(self, ctx, frame):
        for i, color in enumerate(ctx.params["pattern"]):
            frame.set(i % 8, i // 8, color)

    def on_pad_pressed(self, ctx, x, y, button):
        pattern = list(ctx.params["pattern"])
        i = y * 8 + x
        if button == "right":
            pattern[i] = "#000000"
        elif button == "toggle":  # hardware pad: toggle paint/erase
            pattern[i] = "#000000" if pattern[i] != "#000000" else ctx.params["brush"]
        else:
            pattern[i] = ctx.params["brush"]
        ctx.params["pattern"] = pattern
        return True
