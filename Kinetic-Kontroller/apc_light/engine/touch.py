"""Touch reactions: short animations that start from a pressed pad.

A :class:`TouchField` keeps every active reaction (so several presses can
overlap), renders them all into a :class:`~apc_light.engine.compositor.Canvas`
each frame, and drops the ones that have finished. It is effect-agnostic, so
any future interactive effect can reuse it.

Each reaction style is a function ``(touch, px, py, age) -> intensity`` that
is evaluated per pad; intensity is 0..~1 and is screened over what is below.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Tuple

from .compositor import WHITE, Canvas, RGBf, ease_out, gauss, mix

STYLES = ("Ripple", "Horizontal Pulse", "Vertical Pulse", "Bloom", "Spark")
RELEASE = "_release"


@dataclass
class Touch:
    x: int
    y: int
    start: float          # time.monotonic() of the press
    style: str
    duration: float       # seconds until fully faded
    color: RGBf
    strength: float = 1.0  # velocity / intensity scaling (0..1)
    size: float = 1.0      # velocity scaling of spatial reach (~0.7..1)
    sparks: List[Tuple[int, int, float]] = field(default_factory=list)

    def age(self, now: float) -> float:
        return now - self.start


def _flash(t: Touch, d2: float, age: float, tau: float = 0.07) -> float:
    """Bright origin flash in the first ~100 ms."""
    if d2 > 0.01:
        return 0.0
    return math.exp(-age / tau)


def ripple(t: Touch, px: int, py: int, age: float) -> float:
    u = age / t.duration
    dx, dy = px - t.x, py - t.y
    d = math.sqrt(dx * dx + dy * dy)
    reach = 2.0 + 2.0 * t.size            # 2..4 pads
    radius = reach * ease_out(u / 0.85)
    ring = gauss(d - radius, 0.55) * (1.0 - u) ** 1.3
    return max(ring, _flash(t, d, age))


def _pulse(t: Touch, along: int, across: int, age: float) -> float:
    u = age / t.duration
    front = 8.0 * ease_out(u) * (0.75 + 0.25 * t.size)
    lane = 1.0 if across == 0 else (0.16 if abs(across) == 1 else 0.0)
    if lane == 0.0:
        return 0.0
    wave = gauss(abs(along) - front, 0.6) * (1.0 - u) ** 1.2
    # A little light stays behind the fronts so the lane reads as one gesture.
    wake = 0.22 * math.exp(-abs(along) / 2.5) * (1.0 - u) ** 2
    return lane * max(wave, wake, _flash(t, along * along + across * across, age))


def h_pulse(t: Touch, px: int, py: int, age: float) -> float:
    return _pulse(t, px - t.x, py - t.y, age)


def v_pulse(t: Touch, px: int, py: int, age: float) -> float:
    return _pulse(t, py - t.y, px - t.x, age)


def bloom(t: Touch, px: int, py: int, age: float) -> float:
    u = age / t.duration
    dx, dy = px - t.x, py - t.y
    d2 = dx * dx + dy * dy
    # The pressed pad responds instantly; only the surrounding glow eases in.
    attack = 1.0 if d2 == 0 else min(1.0, age / 0.06)
    sigma = (0.7 + 1.0 * u) * (0.8 + 0.3 * t.size)
    glow = math.exp(-d2 / (2 * sigma * sigma))
    env = attack * (1.0 - u) ** 2
    return glow * env * (1.0 if d2 == 0 else 0.75)


def spark(t: Touch, px: int, py: int, age: float) -> float:
    if px == t.x and py == t.y:
        return math.exp(-age / 0.05)
    for sx, sy, delay in t.sparks:
        if sx == px and sy == py and age >= delay:
            return 0.85 * math.exp(-(age - delay) / 0.07)
    return 0.0


def release_fade(t: Touch, px: int, py: int, age: float) -> float:
    if px != t.x or py != t.y:
        return 0.0
    u = age / t.duration
    return (1.0 - u) ** 2  # scaled by t.strength (the held brightness) in render()


STYLE_FUNCS: Dict[str, Callable[[Touch, int, int, float], float]] = {
    "Ripple": ripple,
    "Horizontal Pulse": h_pulse,
    "Vertical Pulse": v_pulse,
    "Bloom": bloom,
    "Spark": spark,
    RELEASE: release_fade,
}

# Pads a style can reach from its origin (keeps per-frame work small).
_REACH = {"Ripple": 5, "Horizontal Pulse": 8, "Vertical Pulse": 8, "Bloom": 3, "Spark": 2, RELEASE: 0}


def make_sparks(x: int, y: int, rng: random.Random) -> List[Tuple[int, int, float]]:
    cells = [(x + dx, y + dy) for dx in (-2, -1, 0, 1, 2) for dy in (-2, -1, 0, 1, 2)
             if (dx or dy) and max(abs(dx), abs(dy)) <= 2 and 0 <= x + dx < 8 and 0 <= y + dy < 8]
    near = [c for c in cells if max(abs(c[0] - x), abs(c[1] - y)) == 1]
    far = [c for c in cells if max(abs(c[0] - x), abs(c[1] - y)) == 2]
    picks = rng.sample(near, min(len(near), 4)) + rng.sample(far, min(len(far), 2))
    return [(cx, cy, (0.012 if max(abs(cx - x), abs(cy - y)) == 1 else 0.035) + rng.random() * 0.02)
            for cx, cy in picks]


class TouchField:
    """All active touch reactions of one effect instance."""

    def __init__(self, max_touches: int = 48) -> None:
        self.touches: List[Touch] = []
        self.max_touches = max_touches

    def add(self, touch: Touch) -> None:
        self.touches.append(touch)
        if len(self.touches) > self.max_touches:
            del self.touches[: len(self.touches) - self.max_touches]

    def clear(self) -> None:
        self.touches.clear()

    def __len__(self) -> int:
        return len(self.touches)

    def render(self, canvas: Canvas, now: float, intensity: float, whiten: float = 0.0) -> None:
        """Screen every live reaction over ``canvas``; expire finished ones."""
        alive: List[Touch] = []
        for t in self.touches:
            age = now - t.start
            if age >= t.duration:
                continue
            alive.append(t)
            if age < 0:
                continue
            fn = STYLE_FUNCS[t.style]
            reach = _REACH.get(t.style, 8)
            k = intensity * t.strength
            color = mix(t.color, WHITE, whiten if t.style != "Spark" else max(whiten, 0.7))
            for py in range(max(0, t.y - reach), min(8, t.y + reach + 1)):
                for px in range(max(0, t.x - reach), min(8, t.x + reach + 1)):
                    v = fn(t, px, py, age)
                    if v > 0.003:
                        canvas.screen(py * 8 + px, color, v * k)
        self.touches = alive
