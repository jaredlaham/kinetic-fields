"""Float compositing for layered effects.

Effects that combine several visual layers (ambient motion, touch reactions,
held-pad highlights, ...) draw into a :class:`Canvas` of 64 RGB values in
*perceptual* units (0..1, roughly "how bright it looks"), blend layers with
``add`` / ``screen`` / ``over``, and convert once at the end with
:meth:`Canvas.to_frame`, which applies a gamma curve to get LED drive values.
Working perceptually makes fades and trails decay evenly to the eye; the LED
output then quantizes to what the APC can show (see midi/output.py).
"""

from __future__ import annotations

import math
from typing import List, Sequence, Tuple

from ..midi.protocol import PAD_COUNT
from .frame import Frame, Pad

RGBf = Tuple[float, float, float]

GAMMA = 2.0  # perceptual value -> LED drive


def hexf(h: str) -> RGBf:
    h = h.lstrip("#")
    return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0, int(h[4:6], 16) / 255.0)


def mix(a: RGBf, b: RGBf, t: float) -> RGBf:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def saturate(c: RGBf, s: float) -> RGBf:
    """s=1 keeps the colour, s=0 gives its grey."""
    g = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
    return (g + (c[0] - g) * s, g + (c[1] - g) * s, g + (c[2] - g) * s)


WHITE: RGBf = (1.0, 1.0, 1.0)


class Gradient:
    """Cyclic colour gradient: ``g(u)`` for any u (wraps every 1.0)."""

    def __init__(self, stops: Sequence[str]) -> None:
        self.colors: List[RGBf] = [hexf(s) for s in stops]
        self.n = len(self.colors)

    def __call__(self, u: float) -> RGBf:
        u = (u % 1.0) * self.n
        i = int(u)
        f = u - i
        f = f * f * (3 - 2 * f)  # smooth between stops (no hard bands)
        return mix(self.colors[i], self.colors[(i + 1) % self.n], f)


# The Kinetic Kontroller retro palette (vintage-Apple rainbow order):
# green -> yellow -> orange -> red -> purple -> blue -> cyan -> (green)
RETRO = Gradient(["#61bb46", "#fdb827", "#f5821f", "#e03a3e", "#963d97", "#009ddc", "#00b5b8"])


class Canvas:
    """64 perceptual RGB values, row-major from the top-left pad."""

    __slots__ = ("r", "g", "b")

    def __init__(self) -> None:
        self.r = [0.0] * PAD_COUNT
        self.g = [0.0] * PAD_COUNT
        self.b = [0.0] * PAD_COUNT

    def clear(self) -> None:
        for arr in (self.r, self.g, self.b):
            for i in range(PAD_COUNT):
                arr[i] = 0.0

    def set(self, i: int, c: RGBf, k: float = 1.0) -> None:
        self.r[i], self.g[i], self.b[i] = c[0] * k, c[1] * k, c[2] * k

    def get(self, i: int) -> RGBf:
        return (self.r[i], self.g[i], self.b[i])

    def add(self, i: int, c: RGBf, k: float) -> None:
        self.r[i] += c[0] * k
        self.g[i] += c[1] * k
        self.b[i] += c[2] * k

    def screen(self, i: int, c: RGBf, k: float) -> None:
        """Light-on-light blend: brightens without hard clipping."""
        if k <= 0.0:
            return
        k = min(k, 1.0)
        self.r[i] = 1.0 - (1.0 - min(self.r[i], 1.0)) * (1.0 - c[0] * k)
        self.g[i] = 1.0 - (1.0 - min(self.g[i], 1.0)) * (1.0 - c[1] * k)
        self.b[i] = 1.0 - (1.0 - min(self.b[i], 1.0)) * (1.0 - c[2] * k)

    def over(self, i: int, c: RGBf, alpha: float) -> None:
        """Paint ``c`` over the pad with opacity ``alpha``."""
        if alpha <= 0.0:
            return
        a = min(alpha, 1.0)
        self.r[i] += (c[0] - self.r[i]) * a
        self.g[i] += (c[1] - self.g[i]) * a
        self.b[i] += (c[2] - self.b[i]) * a

    def to_frame(self, frame: Frame, gamma: float = GAMMA) -> None:
        pads = frame.pads
        for i in range(PAD_COUNT):
            r, g, b = self.r[i], self.g[i], self.b[i]
            if r <= 0.004 and g <= 0.004 and b <= 0.004:
                pads[i] = _OFF
                continue
            pads[i] = Pad((_drive(r, gamma), _drive(g, gamma), _drive(b, gamma)))


_OFF = Pad()


def _drive(v: float, gamma: float) -> int:
    if v <= 0.0:
        return 0
    if v >= 1.0:
        return 255
    return int(round(255.0 * math.pow(v, gamma)))


def gauss(d: float, sigma: float) -> float:
    return math.exp(-(d * d) / (2.0 * sigma * sigma))


def smoothstep(t: float) -> float:
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return t * t * (3 - 2 * t)


def ease_out(t: float) -> float:
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return 1.0 - (1.0 - t) ** 3
