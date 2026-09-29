"""Random — random pads in random colours, forever
(port of apc_random_infinite.sh)."""

from apc_light.engine.effect import BoolParam, Effect, IntParam
from apc_light.engine.frame import BLACK, hsv


class RandomPads(Effect):
    name = "Random"
    category = "Animated"
    description = "Random pads, random colours, never repeats"
    order = 50
    params = [
        IntParam("density", "Density %", 70, 5, 100),
        BoolParam("fade", "Leave gaps", True),
    ]

    def start(self, ctx):
        self._step = -1

    def update(self, ctx, frame):
        step = ctx.step(0.07)
        while self._step < step:
            self._step += 1
            x, y = ctx.rng.randrange(8), ctx.rng.randrange(8)
            lit = ctx.rng.randrange(100) < ctx.params["density"] or not ctx.params["fade"]
            frame.set(x, y, hsv(ctx.rng.random()) if lit else BLACK)
