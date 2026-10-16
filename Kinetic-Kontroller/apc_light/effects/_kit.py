"""Small shared helpers for the interactive effects."""

from __future__ import annotations

import math

from apc_light.engine.compositor import RETRO, WHITE, Canvas, mix  # noqa: F401  (re-exported)

NEIGHBOURS4 = ((1, 0), (-1, 0), (0, 1), (0, -1))


def inb(x: int, y: int) -> bool:
    return 0 <= x < 8 and 0 <= y < 8


def scale(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def ring(d: float, r: float, w: float) -> float:
    return math.exp(-((d - r) ** 2) / (2 * w * w))


def is_pad_event(event) -> bool:
    return hasattr(event, "pressed") and hasattr(event, "x")


PENTATONIC = (0, 2, 4, 7, 9, 12, 14, 16)
MINOR = (0, 2, 3, 5, 7, 8, 10, 12)
MAJOR = (0, 2, 4, 5, 7, 9, 11, 12)
SCALES = {"Pentatonic": PENTATONIC, "Minor": MINOR, "Major": MAJOR}


def lane_note(row: int, scale_name: str, root: int = 48) -> int:
    """MIDI note for a grid row (top row = highest)."""
    steps = SCALES.get(scale_name, PENTATONIC)
    return root + steps[7 - row]
