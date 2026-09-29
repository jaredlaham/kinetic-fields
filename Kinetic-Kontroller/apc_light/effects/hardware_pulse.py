"""Hardware Pulse — the APC's own pulsing/blinking LED modes.

The animation is performed by the APC itself (Note On channels 7-15), so this
costs no MIDI traffic after it starts."""

from apc_light.engine.effect import ChoiceParam, ColorParam, Effect


class HardwarePulse(Effect):
    name = "Hardware Pulse"
    category = "Static"
    description = "Uses the APC's built-in pulse / blink modes"
    animated = False
    order = 40
    params = [
        ColorParam("color", "Color", "#5400ff"),
        ChoiceParam("mode", "Mode", ["Pulse", "Blink"]),
        ChoiceParam("rate", "Rate", ["1/2", "1/4", "1/8", "1/16"], "1/4"),
        ChoiceParam("shape", "Shape", ["Full grid", "Checker", "Border"]),
    ]

    def update(self, ctx, frame):
        mode = "pulse" if ctx.params["mode"] == "Pulse" else "blink"
        shape = ctx.params["shape"]
        frame.clear()
        for x, y in frame.coords():
            if shape == "Checker" and (x + y) % 2:
                continue
            if shape == "Border" and 0 < x < 7 and 0 < y < 7:
                continue
            frame.set(x, y, ctx.params["color"], mode, ctx.params["rate"])
