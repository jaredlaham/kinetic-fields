"""Whack-a-Light — lights pop up on random pads; hit them before they fade.

Green = hit it. Red = don't (costs a life in Endless, time in timed rounds).
Hits build a streak shown on the scene buttons; the game speeds up as you
score. In timed rounds the scene buttons count down the time instead. At the
end of a round the score is spelled out on the pads. With Attract Mode on,
the game plays itself until the first hit.
"""

from __future__ import annotations

import random

from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, IntParam

from ._font import render_columns
from ._kit import WHITE, Canvas, is_pad_event

GOOD, BAD = (0.25, 1.0, 0.3), (1.0, 0.12, 0.08)
LIVES = 3


class WhackALight(Effect):
    name = "Whack-a-Light"
    category = "Games"
    description = "Hit the green lights before they fade; avoid the red ones"
    fps = 50
    accepts_touch = True
    fader_param = "speed"
    hint = ("Hit green pads before they fade, avoid red. Scene buttons show your streak (or the time left). "
            "Tap any pad to start a new round.")
    params = [
        IntParam("speed", "Start speed", 4, 1, 10, ends=("Relaxed", "Frantic")),
        ChoiceParam("round", "Round", ["Endless", "30 s", "60 s"], "30 s"),
        BoolParam("attract", "Attract mode", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.rng = random.Random()
        self.fx = [[0.0, (0, 0, 0)] for _ in range(64)]   # hit/miss splashes
        self._reset(ctx, attract=ctx.params["attract"])

    def _reset(self, ctx, attract=False):
        self.targets = {}          # i -> [t0, life, good]
        self.score = 0
        self.streak = 0
        self.lives = LIVES
        self.spawn_in = 0.4
        self.t_start = ctx.now
        self.over = False
        self.over_t = 0.0
        self.attract = attract
        self.scroll = 0.0
        self.cols = []

    def _duration(self, ctx):
        r = ctx.params["round"]
        return 30.0 if r == "30 s" else 60.0 if r == "60 s" else 0.0

    def _level(self, ctx):
        return ctx.params["speed"] + self.score / 6.0

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if not event.pressed:
                return False
            if self.over:
                if ctx.now - self.over_t > 0.8:
                    self._reset(ctx)
                return False
            if self.attract:
                self._reset(ctx)
                return False
            self._whack(ctx, event.y * 8 + event.x)
            return False
        return super().on_input(ctx, event)

    def _whack(self, ctx, i):
        tgt = self.targets.pop(i, None)
        if tgt is None:
            self.streak = 0
            self.fx[i] = [0.5, (0.35, 0.35, 0.45)]
        elif tgt[2]:
            self.score += 1
            self.streak += 1
            self.fx[i] = [1.0, WHITE]
        else:
            self.streak = 0
            self.fx[i] = [1.0, BAD]
            self._penalty(ctx)

    def _penalty(self, ctx):
        if self._duration(ctx):
            self.t_start -= 3.0
        else:
            self.lives -= 1
            if self.lives <= 0:
                self._game_over(ctx)

    def _game_over(self, ctx):
        self.over, self.over_t = True, ctx.now
        self.targets.clear()
        self.cols = [0] * 8 + render_columns(str(self.score))
        self.scroll = 0.0

    def update(self, ctx, frame):
        dt = min(ctx.real_dt, 0.1)
        if self.over:
            self.scroll += dt * 6.0
            if self.attract or (ctx.params["attract"] and ctx.now - self.over_t > 20):
                self._reset(ctx, attract=True)
        else:
            dur = self._duration(ctx)
            if dur and not self.attract and ctx.now - self.t_start >= dur:
                self._game_over(ctx)
            else:
                self._play(ctx, dt)
        for f in self.fx:
            f[0] = max(0.0, f[0] - dt * 3.0)
        self._draw(ctx, frame)

    def _play(self, ctx, dt):
        level = self._level(ctx)
        life = max(0.45, 1.9 - level * 0.12)
        self.spawn_in -= dt
        if self.spawn_in <= 0 and len(self.targets) < 2 + int(level / 3):
            free = [i for i in range(64) if i not in self.targets]
            i = self.rng.choice(free)
            good = self.rng.random() > (0.0 if self.score < 3 else 0.22)
            self.targets[i] = [ctx.now, life, good]
            self.spawn_in = max(0.18, 0.9 - level * 0.06) * (0.6 + self.rng.random() * 0.8)
        for i, (t0, lf, good) in list(self.targets.items()):
            if self.attract and good and ctx.now - t0 > lf * 0.45:
                self._whack(ctx, i)          # the demo player
                continue
            if ctx.now - t0 > lf:
                del self.targets[i]
                if good and not self.attract:
                    self.streak = 0
                    self._penalty(ctx)
                    if self.over:
                        return
        if self.attract:
            self.score = min(self.score, 30)

    def _draw(self, ctx, frame):
        c = self.canvas
        c.clear()
        if self.over:
            n = len(self.cols)
            off = int(self.scroll) % max(1, n)
            for x in range(8):
                col = self.cols[(off + x) % n] if n else 0
                for y in range(8):
                    if col & (1 << y):
                        c.set(y * 8 + x, (1.0, 0.75, 0.15))
        else:
            for i, (t0, lf, good) in self.targets.items():
                k = 1.0 - (ctx.now - t0) / lf
                c.set(i, GOOD if good else BAD, 0.35 + 0.65 * max(0.0, k))
        for i, (k, col) in enumerate(self.fx):
            if k > 0:
                c.screen(i, col, k)
        c.to_frame(frame)

    def scene_leds(self, ctx):
        if self.over:
            return [2] * 8
        dur = self._duration(ctx)
        if dur and not self.attract:
            left = max(0.0, dur - (ctx.now - self.t_start)) / dur
            n = int(left * 8 + 0.999)
            leds = [1 if (7 - i) < n else 0 for i in range(8)]
            if left < 0.15:
                leds = [2 if v else 0 for v in leds]
            return leds
        if not dur and not self.attract:
            return [1 if i < self.lives else 0 for i in range(3)] + \
                   [1 if i < min(5, self.streak) else 0 for i in range(5)]
        return [1 if i < min(8, self.streak) else 0 for i in range(8)]
