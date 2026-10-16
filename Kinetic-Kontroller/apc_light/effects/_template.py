"""Template for a new effect. Copy to e.g. ``sparkle.py`` (files starting with
an underscore are ignored by discovery)."""

from apc_light.engine.effect import ColorParam, Effect
from apc_light.engine.frame import hsv


class MyEffect(Effect):
    name = "My Effect"          # shown in the scene library
    category = "Animated"       # "Static", "Animated" or "Utility"
    description = "What it does"
    animated = True             # False = draw once (and on parameter changes)
    shortcut = None             # e.g. "7"
    params = [ColorParam("color", "Color", "#00ffcc")]

    def start(self, ctx):
        pass                    # reset any state

    def update(self, ctx, frame):
        # ctx.t = effect time in seconds (already scaled by the SPEED slider)
        # ctx.params["color"] = current value of the color parameter
        frame.clear()
        x = ctx.step(0.1) % 8   # moves one column every 0.1 s at 1x speed
        for y in range(8):
            frame.set(x, y, ctx.params["color"])
            frame.set((x + 4) % 8, y, hsv(ctx.t * 0.2))

    def stop(self):
        pass                    # optional
