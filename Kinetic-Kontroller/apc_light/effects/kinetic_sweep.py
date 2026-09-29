"""Kinetic Sweep — an interactive, layered sweep.

A soft band of light glides across the pads (with optional fading trails)
while every pad you press becomes the origin of its own reaction (ripple,
pulses, bloom, spark). Reactions overlap freely and fade back into the sweep.

Each frame is composited in four layers, in perceptual brightness units,
and converted to LED values once at the end (see engine/compositor.py):

    1. base      faint idle glow (optional; darkness is part of the look)
    2. ambient   the sweep band + trails, in the retro palette
    3. touches   every active reaction, screened over the ambient layer
    4. held      pads currently held down: bright, gently breathing

The engine then diffs the 64 pads and sends only what changed.
"""

from __future__ import annotations

import math
import random
from typing import Dict, List, Tuple

from apc_light.engine.compositor import RETRO, WHITE, Canvas, gauss, mix, saturate, smoothstep
from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, FloatParam, IntParam
from apc_light.engine.touch import RELEASE, STYLES, Touch, TouchField, make_sparks

DIRECTIONS = ["Bounce", "Left → Right", "Right → Left", "Randomized"]

# Hidden "character" parameters, set by presets.
_HIDDEN = dict(hidden=True)


def decay_seconds(slider: float) -> float:
    """Touch Decay 0..100 -> 0.15 s .. 2.0 s (exponential; 50 ~ 0.55 s)."""
    return 0.15 * (2.0 / 0.15) ** (max(0.0, min(100.0, slider)) / 100.0)


def traverse_seconds(slider: float) -> float:
    """Sweep Speed 0..100 -> seconds for one pass across (14 s .. 0.6 s)."""
    return 14.0 * (0.6 / 14.0) ** (max(0.0, min(100.0, slider)) / 100.0)


class KineticSweep(Effect):
    name = "Kinetic Sweep"
    category = "Animated"
    description = "Interactive sweep: press pads to ripple, pulse and bloom light"
    shortcut = "6"
    order = 5
    fps = 50
    accepts_touch = True
    hint = ("Press pads on the APC (or click them here). For the smoothest fades "
            "set LED OUTPUT to RGB.")

    params = [
        IntParam("sweep_speed", "Speed", 40, 0, 100, group="SWEEP", ends=("Slow", "Fast")),
        IntParam("intensity", "Intensity", 55, 0, 100, group="SWEEP"),
        IntParam("trails", "Trails", 45, 0, 100, group="SWEEP", ends=("Off", "High")),
        ChoiceParam("direction", "Direction", DIRECTIONS, "Bounce", group="SWEEP"),
        ChoiceParam("reaction", "Reaction", list(STYLES), "Ripple", group="TOUCH"),
        IntParam("touch_intensity", "Touch Intensity", 90, 0, 100, group="TOUCH"),
        IntParam("touch_decay", "Touch Decay", 45, 0, 100, group="TOUCH", ends=("Short", "Long")),
        BoolParam("velocity", "Velocity", True, group="TOUCH"),
        BoolParam("color_wake", "Color Wake", False, group="TOUCH"),
        # character (preset-controlled)
        FloatParam("band_width", "Band width", 0.85, 0.4, 2.0, **_HIDDEN),
        FloatParam("saturation", "Saturation", 0.95, 0.0, 1.0, **_HIDDEN),
        FloatParam("base_glow", "Base glow", 0.03, 0.0, 0.3, **_HIDDEN),
        FloatParam("palette_drift", "Palette drift", 0.035, 0.0, 0.2, **_HIDDEN),
        FloatParam("touch_white", "Touch whiteness", 0.35, 0.0, 1.0, **_HIDDEN),
    ]

    presets = {
        "OXI": dict(sweep_speed=35, intensity=40, trails=55, direction="Bounce", reaction="Horizontal Pulse",
                    touch_intensity=85, touch_decay=40, velocity=True, color_wake=False, band_width=0.7,
                    saturation=0.55, base_glow=0.0, palette_drift=0.015, touch_white=0.55),
        "RETRO": dict(sweep_speed=45, intensity=60, trails=45, direction="Bounce", reaction="Ripple",
                      touch_intensity=90, touch_decay=45, velocity=True, color_wake=True, band_width=0.9,
                      saturation=1.0, base_glow=0.04, palette_drift=0.04, touch_white=0.35),
        "NEON": dict(sweep_speed=55, intensity=30, trails=35, direction="Bounce", reaction="Ripple",
                     touch_intensity=100, touch_decay=50, velocity=True, color_wake=True, band_width=0.75,
                     saturation=1.0, base_glow=0.0, palette_drift=0.06, touch_white=0.0),
        "AMBIENT": dict(sweep_speed=15, intensity=50, trails=90, direction="Bounce", reaction="Bloom",
                        touch_intensity=70, touch_decay=80, velocity=True, color_wake=True, band_width=1.3,
                        saturation=0.8, base_glow=0.05, palette_drift=0.02, touch_white=0.3),
        "PERFORMANCE": dict(sweep_speed=75, intensity=45, trails=25, direction="Bounce", reaction="Spark",
                            touch_intensity=100, touch_decay=12, velocity=True, color_wake=False, band_width=0.7,
                            saturation=0.9, base_glow=0.0, palette_drift=0.05, touch_white=0.6),
        "ZEN": dict(sweep_speed=5, intensity=35, trails=95, direction="Bounce", reaction="Ripple",
                    touch_intensity=55, touch_decay=90, velocity=True, color_wake=False, band_width=1.6,
                    saturation=0.6, base_glow=0.03, palette_drift=0.01, touch_white=0.25),
    }

    # ------------------------------------------------------------------
    def start(self, ctx):
        self.canvas = Canvas()
        self.touches = TouchField()
        self.trail = [0.0] * 64
        self.phase = 0.0          # sweep progress (1.0 = one pass)
        self.hue = 0.0            # palette drift
        self.pos = 3.5            # band centre (columns, may leave the grid)
        self.wakes: List[Tuple[int, int, Tuple[float, float, float], float]] = []
        self.held_color: Dict[Tuple[int, int], Tuple[float, float, float]] = {}
        self.rng = random.Random()
        # Randomized-direction segment state
        self.seg_from, self.seg_to, self.seg_t, self.seg_dur = 3.5, 0.0, 0.0, 1.0
        self._new_segment(ctx.params)

    # ------------------------------------------------------------------ input
    def on_input(self, ctx, event):
        p = ctx.params
        key = (event.x, event.y)
        if event.pressed:
            vf = 1.0
            if p["velocity"]:
                vf = 0.7 + 0.3 * (event.velocity / 127.0)   # subtle; APC pads often send 127
            color = self._ambient_color(event.x, event.y)
            dur = decay_seconds(p["touch_decay"])
            style = p["reaction"]
            if style == "Spark":
                dur = min(0.45, max(0.14, dur * 0.5))
            touch = Touch(event.x, event.y, ctx.now, style, dur, color, strength=vf, size=vf)
            if style == "Spark":
                touch.sparks = make_sparks(event.x, event.y, self.rng)
            self.touches.add(touch)
            self.held_color[key] = color
            if p["color_wake"]:
                self.wakes.append((event.x, event.y, color, ctx.now))
                del self.wakes[:-12]
        else:
            color = self.held_color.pop(key, None)
            if color is not None:
                level = self._held_level(ctx.now) * p["touch_intensity"] / 100.0
                self.touches.add(Touch(event.x, event.y, ctx.now, RELEASE, 0.28, self._held_tint(color, p),
                                       strength=level))
        return False  # parameters unchanged

    # ------------------------------------------------------------------ motion
    def _new_segment(self, p):
        self.seg_from = self.pos
        target = self.pos
        while abs(target - self.pos) < 2.0:
            target = self.rng.uniform(0.0, 7.0)
        self.seg_to = target
        self.seg_t = 0.0
        self.seg_dur = max(0.35, abs(target - self.pos) / 7.0) * traverse_seconds(p["sweep_speed"])

    def _advance(self, ctx):
        p = ctx.params
        dt = ctx.dt  # already scaled by the global SPEED slider
        T = traverse_seconds(p["sweep_speed"])
        direction = p["direction"]
        margin = 2.5  # band fully leaves the grid before wrapping (no teleport)
        if direction == "Randomized":
            self.seg_t += dt
            self.pos = self.seg_from + (self.seg_to - self.seg_from) * smoothstep(self.seg_t / self.seg_dur)
            if self.seg_t >= self.seg_dur:
                self._new_segment(p)
        else:
            self.phase += dt / T
            if direction == "Bounce":
                # Cosine easing: slows into each edge and turns around smoothly.
                self.pos = 3.5 - 4.0 * math.cos(math.pi * self.phase)
            else:
                span = 7.0 + 2 * margin
                x = -margin + (self.phase % 1.0) * span
                self.pos = x if direction == "Left → Right" else 7.0 - x
        self.hue += dt * p["palette_drift"]

    def _ambient_color(self, x: int, y: int) -> Tuple[float, float, float]:
        return RETRO(self.hue + x * 0.06 + y * 0.015)

    def _held_level(self, now: float) -> float:
        return 0.93 + 0.07 * math.sin(now * 2 * math.pi / 1.6)   # slow, subtle breathing

    @staticmethod
    def _held_tint(color, p):
        return mix(color, WHITE, 0.25 + 0.5 * p["touch_white"])

    # ------------------------------------------------------------------ render
    def update(self, ctx, frame):
        p = ctx.params
        now = ctx.now
        self._advance(ctx)
        c = self.canvas
        amb = p["intensity"] / 100.0
        sigma = p["band_width"]
        sat = p["saturation"]
        # Trails decay with sweep time, so their length in pads stays similar
        # at any speed. 0 = no trail, 100 = long glow (~1.4 s at 1x).
        tau = (p["trails"] / 100.0) ** 1.5 * 1.4
        keep = math.exp(-ctx.dt / tau) if tau > 0.01 else 0.0

        # Color Wake: recent touches tint the ambient colour as they drift away.
        wakes = []
        for (wx, wy, wc, ws) in self.wakes:
            age = now - ws
            if age < 3.0:
                wakes.append((wx, wy, wc, age))
        self.wakes = [w for w in self.wakes if now - w[3] < 3.0]

        base = p["base_glow"]
        for y in range(8):
            # A gentle, travelling curve in the band front makes the motion fluid
            # instead of a rigid column.
            bend = 0.35 * math.sin(y * 0.55 + self.phase * 2.1 + self.hue * 3.0)
            for x in range(8):
                i = y * 8 + x
                d = x - (self.pos + bend)
                band = gauss(d, sigma)
                t = self.trail[i] * keep
                if band > t:
                    t = band
                self.trail[i] = t
                level = max(band, 0.8 * t)
                # Adjacent columns drift along the palette -> colour depth.
                col = RETRO(self.hue + x * 0.06 + y * 0.015 + (1.0 - band) * 0.07)
                for (wx, wy, wc, age) in wakes:
                    w = 0.45 * math.exp(-age / 1.2) * gauss(abs(x - wx) - 3.0 * age, 1.0) * gauss(y - wy, 2.2)
                    if w > 0.01:
                        col = mix(col, wc, min(w, 0.6))
                col = saturate(col, sat)
                # Layer 1 (base) + Layer 2 (ambient)
                v = amb * level * (0.35 + 0.65 * level)   # hierarchy: centre >> edges
                c.set(i, col, max(v, base * (0.6 + 0.4 * level)))

        # Layer 3: touch reactions (all active ones, overlapping)
        ti = p["touch_intensity"] / 100.0
        self.touches.render(c, now, ti, whiten=p["touch_white"] * 0.6)

        # Layer 4: pads held down stay bright and breathe
        held = ctx.interaction.held if ctx.interaction is not None else {}
        if held:
            level = self._held_level(now) * ti
            for (hx, hy) in held:
                color = self.held_color.get((hx, hy)) or self._ambient_color(hx, hy)
                c.over(hy * 8 + hx, self._held_tint(color, p), level)

        c.to_frame(frame)

    def stop(self):
        self.touches.clear()
        self.wakes.clear()
        self.held_color.clear()
