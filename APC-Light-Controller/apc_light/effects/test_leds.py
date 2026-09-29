"""Test LEDs — walks every pad, then flashes the whole grid R/G/B/W so dead
LEDs or wrong mappings are obvious."""

from apc_light.engine.effect import Effect
from apc_light.engine.frame import hsv

PHASES = ["#ff0000", "#00ff00", "#0000ff", "#ffffff"]


class TestLeds(Effect):
    name = "Test LEDs"
    category = "Utility"
    description = "Pad-by-pad walk, then full red/green/blue/white"
    order = 10

    def update(self, ctx, frame):
        step = ctx.step(0.06) % (64 + len(PHASES) * 12)
        frame.clear()
        if step < 64:
            # Walk in reading order from the top-left pad.
            for i in range(step + 1):
                frame.set(i % 8, i // 8, hsv(i / 64))
        else:
            frame.fill(PHASES[(step - 64) // 12])
