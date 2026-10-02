"""Fireworks — tap a pad to launch a rocket from the bottom row; it bursts
into a ring of embers at the pad you tapped. Harder hits make bigger
shells. With Auto Show on, rockets launch by themselves between taps."""

from __future__ import annotations

import math
import random

from apc_light.engine.effect import BoolParam, Effect, IntParam

from ._kit import RETRO, WHITE, Canvas, is_pad_event, mix


class Fireworks(Effect):
    name = "Fireworks"
    category = "Interactive"
    description = "Tap pads to launch rockets that burst into embers"
    fps = 50
    accepts_touch = True
    fader_param = "size"
    hint = "Tap a pad: a rocket climbs to it and bursts. Hit harder for bigger shells. Master fader = shell size."
    params = [
        IntParam("size", "Shell size", 18, 6, 40, ends=("Small", "Huge")),
        IntParam("gravity", "Gravity", 4, 0, 10, ends=("Float", "Heavy")),
        BoolParam("auto", "Auto show", True),
    ]

    def start(self, ctx):
        self.canvas = Canvas()
        self.rng = random.Random()
        self.rockets = []      # [x, y, target_y, hue, power]
        self.embers = []       # [x, y, vx, vy, life, hue]
        self.flash = 0.0
        self.next_auto = 0.8

    def _launch(self, x, ty, power, hue=None):
        hue = self.rng.random() if hue is None else hue
        self.rockets.append([float(x), 7.6, float(ty), hue, power])

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if event.pressed:
                self._launch(event.x, event.y, max(0.35, event.velocity / 127.0))
                self.next_auto = 3.0
            return False
        return super().on_input(ctx, event)

    def _burst(self, ctx, x, y, hue, power):
        n = int(ctx.params["size"] * (0.5 + power * 0.7))
        speed = 2.2 + power * 3.0
        for k in range(n):
            a = (k / n) * math.tau + self.rng.random() * 0.3
            s = speed * (0.55 + self.rng.random() * 0.45)
            h = hue + (self.rng.random() - 0.5) * 0.12
            self.embers.append([x, y, math.cos(a) * s, math.sin(a) * s, 1.0, h])
        del self.embers[:-400]
        self.flash = max(self.flash, 0.25 * power)

    def update(self, ctx, frame):
        dt = min(ctx.dt, 0.05)
        p = ctx.params
        if p["auto"]:
            self.next_auto -= dt
            if self.next_auto <= 0:
                self._launch(self.rng.randint(1, 6), self.rng.randint(1, 3), 0.5 + self.rng.random() * 0.5)
                self.next_auto = 0.6 + self.rng.random() * 1.4
        alive = []
        for r in self.rockets:
            r[1] -= dt * 11.0
            if r[1] <= r[2]:
                self._burst(ctx, r[0], r[2], r[3], r[4])
            else:
                alive.append(r)
        self.rockets = alive
        g = p["gravity"] * 0.9
        drag = math.exp(-dt * 2.2)
        alive = []
        for e in self.embers:
            e[2] *= drag
            e[3] = e[3] * drag + g * dt
            e[0] += e[2] * dt
            e[1] += e[3] * dt
            e[4] -= dt * 0.9
            if e[4] > 0 and -1.5 < e[0] < 8.5 and e[1] < 9:
                alive.append(e)
        self.embers = alive
        self.flash = max(0.0, self.flash - dt * 2.5)
        self._draw(frame)

    def _draw(self, frame):
        c = self.canvas
        c.clear()
        if self.flash > 0:
            for i in range(64):
                c.add(i, (0.5, 0.45, 0.4), self.flash * 0.35)
        for x, y, vx, vy, life, hue in self.embers:
            ix, iy = int(round(x)), int(round(y))
            if 0 <= ix < 8 and 0 <= iy < 8:
                col = mix(RETRO(hue), WHITE, max(0.0, life - 0.75) * 3.0)
                c.screen(iy * 8 + ix, col, life * 0.9)
        for x, y, ty, hue, _ in self.rockets:
            ix, iy = int(round(x)), int(round(y))
            for k, yy in enumerate((iy, iy + 1)):
                if 0 <= yy < 8:
                    c.screen(yy * 8 + ix, (1.0, 0.85, 0.55), 1.0 if k == 0 else 0.35)
        c.to_frame(frame)
