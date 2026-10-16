"""Kinetic Marquee — scrolling text (port of apc_kinetic_marquee.py)."""

from apc_light.engine.effect import ChoiceParam, ColorParam, Effect, TextParam
from apc_light.engine.frame import hsv, to_rgb

from ._font import render_columns


class KineticMarquee(Effect):
    name = "Kinetic Marquee"
    category = "Animated"
    description = "Scrolling text across the pads"
    shortcut = "6"
    order = 60
    params = [
        TextParam("text", "Text", "KINETIC FIELDS"),
        ChoiceParam("coloring", "Colour mode", ["Rainbow", "Solid", "Rainbow per letter"]),
        ColorParam("color", "Colour", "#00a9ff"),
        ColorParam("background", "Background", "#000000"),
        ChoiceParam("row", "Vertical position", ["Top", "Bottom"], "Top"),
    ]

    def start(self, ctx):
        self._text = None
        self._cols = []

    def update(self, ctx, frame):
        text = ctx.params["text"] or " "
        if text != self._text:
            self._text = text
            self._cols = [0] * 8 + render_columns(text)  # start off-screen right
        cols = self._cols
        offset = ctx.step(0.09) % len(cols)
        y0 = {"Top": 0, "Bottom": 1}[ctx.params["row"]]
        solid = to_rgb(ctx.params["color"])
        frame.fill(ctx.params["background"])
        mode = ctx.params["coloring"]
        for x in range(8):
            ci = (offset + x) % len(cols)
            bits = cols[ci]
            if not bits:
                continue
            if mode == "Solid":
                color = solid
            elif mode == "Rainbow":
                color = hsv(ctx.t * 0.2 + x / 12)
            else:
                color = hsv(ci / 24)
            for y in range(7):
                if bits >> y & 1:
                    frame.set(x, y + y0, color)
