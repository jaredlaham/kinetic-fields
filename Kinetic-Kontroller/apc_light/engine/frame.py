"""Frames: the 8x8 LED image effects draw into.

Coordinates are ``(x, y)`` with ``x`` left->right and ``y`` TOP->bottom, which
is how you look at the APC. The MIDI layer converts to note numbers.
"""

from __future__ import annotations

import colorsys
from dataclasses import dataclass
from typing import Iterator, List, Tuple, Union

from ..midi.protocol import GRID_H, GRID_W, PAD_COUNT

RGB = Tuple[int, int, int]
ColorLike = Union[RGB, str]

BLACK: RGB = (0, 0, 0)


@dataclass(frozen=True)
class Pad:
    """One pad's requested state.

    ``mode`` is ``"solid"``, ``"pulse"`` or ``"blink"``; ``rate`` is the
    hardware rate label (``"1/16"``, ``"1/8"``, ``"1/4"``, ``"1/2"``, plus
    ``"1/24"`` for blink). Pulse/blink are performed by the APC itself.
    """

    rgb: RGB = BLACK
    mode: str = "solid"
    rate: str = "1/4"

    @property
    def is_off(self) -> bool:
        return self.rgb == BLACK


OFF = Pad()


def to_rgb(color: ColorLike) -> RGB:
    if isinstance(color, str):
        h = color.lstrip("#")
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    r, g, b = color
    return (_clamp(r), _clamp(g), _clamp(b))


def to_hex(rgb: RGB) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def hsv(h: float, s: float = 1.0, v: float = 1.0) -> RGB:
    """Hue in turns (0..1, wraps), saturation/value 0..1."""
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, max(0.0, min(1.0, s)), max(0.0, min(1.0, v)))
    return (_clamp(r * 255), _clamp(g * 255), _clamp(b * 255))


def scale(rgb: RGB, k: float) -> RGB:
    return (_clamp(rgb[0] * k), _clamp(rgb[1] * k), _clamp(rgb[2] * k))


def lerp(a: RGB, b: RGB, t: float) -> RGB:
    t = max(0.0, min(1.0, t))
    return (_clamp(a[0] + (b[0] - a[0]) * t), _clamp(a[1] + (b[1] - a[1]) * t), _clamp(a[2] + (b[2] - a[2]) * t))


def _clamp(v: float) -> int:
    return 0 if v <= 0 else 255 if v >= 255 else int(round(v))


class Frame:
    """A mutable 8x8 grid of :class:`Pad` values."""

    __slots__ = ("pads",)
    width = GRID_W
    height = GRID_H

    def __init__(self, pads: List[Pad] | None = None) -> None:
        self.pads: List[Pad] = list(pads) if pads is not None else [OFF] * PAD_COUNT

    # -- drawing ---------------------------------------------------------
    def set(self, x: int, y: int, color: ColorLike, mode: str = "solid", rate: str = "1/4") -> None:
        if 0 <= x < GRID_W and 0 <= y < GRID_H:
            self.pads[y * GRID_W + x] = Pad(to_rgb(color), mode, rate)

    def get(self, x: int, y: int) -> Pad:
        return self.pads[y * GRID_W + x]

    def fill(self, color: ColorLike, mode: str = "solid", rate: str = "1/4") -> None:
        pad = Pad(to_rgb(color), mode, rate)
        self.pads = [pad] * PAD_COUNT

    def clear(self) -> None:
        self.pads = [OFF] * PAD_COUNT

    def draw_bitmap(self, rows: List[str], colors: dict, x0: int = 0, y0: int = 0) -> None:
        """Draw an ASCII bitmap. Each character is looked up in ``colors``;
        characters missing from the map (e.g. ``"."``) are left untouched."""
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch in colors:
                    self.set(x0 + dx, y0 + dy, colors[ch])

    # -- misc ------------------------------------------------------------
    def copy(self) -> "Frame":
        return Frame(self.pads)

    def coords(self) -> Iterator[Tuple[int, int]]:
        for y in range(GRID_H):
            for x in range(GRID_W):
                yield x, y

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Frame) and self.pads == other.pads

    def __repr__(self) -> str:  # pragma: no cover - debug helper
        lit = sum(1 for p in self.pads if not p.is_off)
        return f"<Frame {lit}/64 lit>"
