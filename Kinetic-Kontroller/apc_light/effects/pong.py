"""Pong — two-player Pong on the pads, played with the APC's faders.

Fader 1 moves the left paddle (column 1), fader 8 the right paddle (column 8).
A side the faders haven't touched for a while is played by the computer, so
it also works as a one-player game or an attract mode. Tapping a pad in an
edge column moves that paddle there; tapping elsewhere serves.
The score lights the scene buttons: top four = left player, bottom four =
right player. First to four wins.
"""

from __future__ import annotations

import math
import random

from apc_light.engine.effect import ChoiceParam, Effect, IntParam

from ._kit import WHITE, Canvas, is_pad_event

LEFT_FADER, RIGHT_FADER = 0, 7
MANUAL_HOLD = 10.0   # seconds a fader keeps control after it last moved
WIN = 4


class Pong(Effect):
    name = "Pong"
    category = "Games"
    description = "Two-player Pong: faders 1 and 8 are the paddles"
    fps = 50
    accepts_touch = True
    fader_param = "speed"
    hint = ("Fader 1 = left paddle, fader 8 = right paddle (drag the on-screen faders too). An untouched "
            "side is played by the computer. Master fader = ball speed. Tap a pad to serve.")
    params = [
        IntParam("speed", "Ball speed", 5, 1, 10, ends=("Calm", "Fast")),
        ChoiceParam("paddle", "Paddle size", ["2", "3", "4"], "3"),
        ChoiceParam("left", "Left player", ["Fader 1", "Computer"], "Fader 1"),
        ChoiceParam("right", "Right player", ["Fader 8", "Computer"], "Fader 8"),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.rng = random.Random()
        self.paddle = [2.5, 2.5]          # top row of each paddle (float)
        self.target = [2.5, 2.5]
        self.manual_until = [0.0, 0.0]
        self.score = [0, 0]
        self.flash = 0.0
        self.flash_side = 0
        self.winner = -1
        self.win_t = 0.0
        self.trail = []
        self.wait = 0.6                   # pause before the next serve
        self._serve(1 if self.rng.random() < 0.5 else -1)

    def _serve(self, direction):
        self.bx, self.by = 3.5, 1.0 + self.rng.random() * 5.0
        self.vx, self.vy = 3.3 * direction, (self.rng.random() - 0.5) * 3.0
        self.rally = 1.0
        self.trail = []

    # ------------------------------------------------------------------ input
    def on_input(self, ctx, event):
        if is_pad_event(event):
            if not event.pressed:
                return False
            if event.x in (0, 7):
                side = 0 if event.x == 0 else 1
                self.target[side] = min(8 - self._size(ctx), max(0, event.y - self._size(ctx) / 2 + 0.5))
                self.manual_until[side] = ctx.now + MANUAL_HOLD
            elif self.wait > 0 or self.winner >= 0:
                self.wait = 0
            return False
        if event.index in (LEFT_FADER, RIGHT_FADER):
            side = 0 if event.index == LEFT_FADER else 1
            # fader up = paddle up (row 0 is the top)
            self.target[side] = (1.0 - event.value / 127.0) * (8 - self._size(ctx))
            self.manual_until[side] = ctx.now + MANUAL_HOLD
            return False
        return super().on_input(ctx, event)

    def _size(self, ctx):
        return int(ctx.params["paddle"])

    def _manual(self, ctx, side):
        mode = ctx.params["left" if side == 0 else "right"]
        return mode.startswith("Fader") and ctx.now < self.manual_until[side]

    # ------------------------------------------------------------------ game
    def update(self, ctx, frame):
        dt = min(ctx.dt, 0.05)
        size = self._size(ctx)
        span = 8 - size
        # paddles: manual -> fader target, else a slightly imperfect computer
        for side in (0, 1):
            if not self._manual(ctx, side):
                lag = 0.35 * math.sin(ctx.t * (0.7 + side * 0.4))
                self.target[side] = min(span, max(0.0, self.by - size / 2 + 0.5 + lag))
            rate = 16 if self._manual(ctx, side) else 4.2
            self.paddle[side] += (self.target[side] - self.paddle[side]) * min(1.0, dt * rate)

        if self.winner >= 0:
            if ctx.now - self.win_t > 2.4:
                self.score = [0, 0]
                self.winner = -1
                self.wait = 0.8
                self._serve(1)
        elif self.wait > 0:
            self.wait -= dt
        else:
            sp = (0.45 + ctx.params["speed"] * 0.11) * self.rally
            self.bx += self.vx * sp * dt
            self.by += self.vy * sp * dt
            if self.by < 0:
                self.by, self.vy = -self.by, -self.vy
            if self.by > 7:
                self.by, self.vy = 14 - self.by, -self.vy
            for side, edge, inside in ((0, 1.0, lambda: self.vx < 0), (1, 6.0, lambda: self.vx > 0)):
                past = self.bx < edge if side == 0 else self.bx > edge
                if past and inside():
                    top = self.paddle[side]
                    if top - 0.6 <= self.by <= top + size - 0.4:
                        self.bx = 2 * edge - self.bx
                        self.vx = -self.vx
                        self.vy += (self.by - (top + size / 2 - 0.5)) * 1.3
                        self.vy = max(-5.0, min(5.0, self.vy))
                        self.rally = min(2.6, self.rally + 0.09)
                    elif (side == 0 and self.bx < -0.6) or (side == 1 and self.bx > 7.6):
                        scorer = 1 - side
                        self.score[scorer] += 1
                        self.flash, self.flash_side = 1.0, side
                        if self.score[scorer] >= WIN:
                            self.winner, self.win_t = scorer, ctx.now
                        self.wait = 0.9
                        self._serve(1 if side == 0 else -1)
            self.trail.insert(0, (self.bx, self.by))
            del self.trail[6:]
        self.flash = max(0.0, self.flash - dt * 2.0)
        self._draw(ctx, frame, size)

    def _draw(self, ctx, frame, size):
        c = self.canvas
        c.clear()
        if self.flash > 0:
            for y in range(8):
                for x in range(4 * self.flash_side, 4 * self.flash_side + 4):
                    c.set(y * 8 + x, (0.95, 0.15, 0.12), self.flash * 0.6)
        if self.winner >= 0:
            col = (0.0, 0.7, 0.95) if self.winner == 0 else (1.0, 0.55, 0.15)
            k = 0.35 + 0.35 * math.sin(ctx.now * 9)
            for i in range(64):
                c.screen(i, col, k)
        for side, col in ((0, (0.0, 0.72, 0.95)), (1, (1.0, 0.56, 0.14))):
            x = 0 if side == 0 else 7
            top = int(round(self.paddle[side]))
            for y in range(top, top + size):
                if 0 <= y < 8:
                    c.set(y * 8 + x, col)
        if self.winner < 0:
            for k, (tx, ty) in enumerate(self.trail):
                x, y = int(round(min(7, max(0, tx)))), int(round(min(7, max(0, ty))))
                c.screen(y * 8 + x, WHITE if k == 0 else (1.0, 0.75, 0.2), 1.0 if k == 0 else 0.55 / k)
        c.to_frame(frame)

    def scene_leds(self, ctx):
        left, right = self.score
        leds = [1 if i < left else 0 for i in range(4)] + [1 if (3 - i) < right else 0 for i in range(4)]
        if self.winner >= 0:
            leds = [2] * 4 + [0] * 4 if self.winner == 0 else [0] * 4 + [2] * 4
        return leds
