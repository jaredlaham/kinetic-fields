"""The APC mini mk2 built-in 128-colour velocity palette.

Velocity N on a pad Note On shows ``PALETTE[N]`` (from the colour table in the
official communication protocol document). Used for:

* palette output mode (Note On colours, brightness via MIDI channel), and
* showing palette-based colours accurately in the on-screen visualizer.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Tuple

RGB = Tuple[int, int, int]

_HEX = (
    "000000 1E1E1E 7F7F7F FFFFFF FF4C4C FF0000 590000 190000 "
    "FFBD6C FF5400 591D00 271B00 FFFF4C FFFF00 595900 191900 "
    "88FF4C 54FF00 1D5900 142B00 4CFF4C 00FF00 005900 001900 "
    "4CFF5E 00FF19 00590D 001902 4CFF88 00FF55 00591D 001F12 "
    "4CFFB7 00FF99 005935 001912 4CC3FF 00A9FF 004152 001019 "
    "4C88FF 0055FF 001D59 000819 4C4CFF 0000FF 000059 000019 "
    "874CFF 5400FF 190064 0F0030 FF4CFF FF00FF 590059 190019 "
    "FF4C87 FF0054 59001D 220013 FF1500 993500 795100 436400 "
    "033900 005735 00547F 0000FF 00454F 2500CC 7F7F7F 202020 "
    "FF0000 BDFF2D AFED06 64FF09 108B00 00FF87 00A9FF 002AFF "
    "3F00FF 7A00FF B21A7D 402100 FF4A00 88E106 72FF15 00FF00 "
    "3BFF26 59FF71 38FFCC 5B8AFF 3151C6 877FE9 D31DFF FF005D "
    "FF7F00 B9B000 90FF00 835D07 392B00 144C10 0D5038 15152A "
    "16205A 693C1C A8000A DE513D D86A1C FFE126 9EE12F 67B50F "
    "1E1E30 DCFF6B 80FFBD 9A99FF 8E66FF 404040 757575 E0FFFF "
    "A00000 350000 1AD000 074200 B9B000 3F3100 B35F00 4B1502"
).split()

PALETTE: Tuple[RGB, ...] = tuple(
    (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)) for h in _HEX
)
assert len(PALETTE) == 128

# Named indices used by effects that want exact hardware colours.
BLACK, DARK_GREY, GREY, WHITE = 0, 1, 2, 3
RED, ORANGE, YELLOW, LIME, GREEN = 5, 9, 13, 17, 21
SPRING, CYAN, SKY, BLUE, PURPLE, MAGENTA, PINK = 29, 33, 37, 45, 49, 53, 57


@lru_cache(maxsize=8192)
def nearest_index(rgb: RGB) -> int:
    """Closest palette velocity for an RGB colour (0 only for true black)."""
    r, g, b = rgb
    if r == g == b == 0:
        return 0
    best, best_d = 1, 1 << 30
    for i in range(1, 128):
        pr, pg, pb = PALETTE[i]
        # Weighted distance approximating perceived difference.
        dr, dg, db = r - pr, g - pg, b - pb
        d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
        if d < best_d:
            best, best_d = i, d
    return best


# ----------------------------------------------------------------------------
# Per-pad colour + brightness quantizer
# ----------------------------------------------------------------------------
# The Note On *channel* (0..6) sets each pad's brightness to 10..100 %, and the
# velocity picks one of 127 palette colours, so every pad can show one of
# 127 x 7 = 889 colour/brightness combinations. Picking the best combination
# per pad gives far smoother fades than "nearest palette colour at a fixed
# brightness". Distances are measured in a perceptual (square-root) space.

import math as _math

from .protocol import BRIGHTNESS_LEVELS as _LEVELS


def _perceptual(rgb) -> tuple:
    return tuple(_math.sqrt(c / 255.0) for c in rgb)


_CANDIDATES = []
for _v in range(1, 128):
    for _ch, _lvl in enumerate(_LEVELS):
        _eff = tuple(c * _lvl / 100.0 for c in PALETTE[_v])
        _p = _perceptual(_eff)
        _m = max(_p) or 1.0
        _CANDIDATES.append((_v, _ch, _p, (_p[0] / _m, _p[1] / _m, _p[2] / _m)))

_CHROMA_WEIGHT = 2.0  # extra weight on hue/chroma, scaled by brightness (tuned on the retro palette)


def perceptual_quantize(rgb: RGB, steps: int = 48) -> RGB:
    """Snap a drive colour to ``steps`` perceptually even levels per channel.

    Used for both output modes so tiny, invisible changes don't generate MIDI
    traffic, while slow fades stay smooth to the eye."""
    out = []
    for c in rgb:
        q = round(_math.sqrt(max(0, min(255, c)) / 255.0) * steps) / steps
        out.append(int(round(q * q * 255)))
    return (out[0], out[1], out[2])


@lru_cache(maxsize=32768)
def best_note(rgb: RGB) -> tuple:
    """(velocity, channel) whose effective colour best matches ``rgb`` (a drive
    colour that already includes global brightness). (0, 0) = off."""
    if max(rgb) < 3:
        return (0, 0)
    tr, tg, tb = _perceptual(rgb)
    lt = max(tr, tg, tb)
    cr, cg, cb = tr / lt, tg / lt, tb / lt
    cw = _CHROMA_WEIGHT * lt * lt
    best, best_d = (0, 0), 1e9
    for v, ch, (pr, pg, pb), (qr, qg, qb) in _CANDIDATES:
        dr, dg, db = tr - pr, tg - pg, tb - pb
        d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
        if d >= best_d:
            continue
        er, eg, eb = cr - qr, cg - qg, cb - qb
        d += cw * (er * er + eg * eg + eb * eb)
        if d < best_d:
            best, best_d = (v, ch), d
    # Leave a pad dark rather than light it far too bright.
    off_d = 3 * tr * tr + 4 * tg * tg + 2 * tb * tb
    return (0, 0) if off_d < best_d else best


def effective_color(velocity: int, channel: int) -> RGB:
    """Approximate drive colour of a pad lit with (velocity, channel 0..6)."""
    if velocity <= 0:
        return (0, 0, 0)
    lvl = _LEVELS[min(channel, len(_LEVELS) - 1)] / 100.0
    r, g, b = PALETTE[velocity]
    return (int(r * lvl), int(g * lvl), int(b * lvl))
