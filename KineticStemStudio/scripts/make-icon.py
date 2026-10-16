"""Draws Resources/AppIcon-1024.png: a waveform on the left turning into MIDI
note blocks on the right, on Apple's macOS icon grid (824 px body, 100 px margin).
Needs only numpy.  Run: python3 scripts/make-icon.py"""
import struct
import zlib
from pathlib import Path

import numpy as np

S = 1024
SS = 4  # supersampling
N = S * SS
y, x = np.mgrid[0:N, 0:N].astype(np.float32) / SS


def rounded_rect(x0, y0, x1, y1, r):
    cx = np.clip(x, x0 + r, x1 - r)
    cy = np.clip(y, y0 + r, y1 - r)
    return ((x - cx) ** 2 + (y - cy) ** 2 <= r * r) & (x >= x0) & (x <= x1) & (y >= y0) & (y <= y1)


img = np.zeros((N, N, 4), np.float32)
body = rounded_rect(100, 100, 924, 924, 185)
t = (y - 100) / 824
bg = np.stack([0.075 + 0.05 * (1 - t), 0.078 + 0.05 * (1 - t), 0.09 + 0.06 * (1 - t)], -1)
img[..., :3] = bg
img[..., 3] = body

orange = np.array([1.0, 0.45, 0.16])
gold = np.array([1.0, 0.78, 0.3])
mid = 512
# Waveform: thin vertical bars with a decaying envelope (left side).
rng = np.random.default_rng(7)
for i in range(22):
    cx = 190 + i * 15
    env = 0.25 + 0.75 * abs(np.sin(i * 0.55)) * np.exp(-((i - 6) ** 2) / 60)
    h = 40 + 230 * env * (0.7 + 0.3 * rng.random())
    m = rounded_rect(cx - 4, mid - h, cx + 4, mid + h, 4)
    a = 0.35 + 0.65 * (i / 21)
    img[m, :3] = img[m, :3] * (1 - a) + orange * a
# MIDI note blocks (right side), on three rows.
notes = [(520, 590, 330), (600, 690, 420), (700, 760, 330), (770, 850, 250), (600, 650, 600), (690, 820, 520)]
for x0, x1, yc in notes:
    m = rounded_rect(x0, yc - 34, x1, yc + 34, 14)
    c = orange + (gold - orange) * ((yc - 250) / 350)
    img[m, :3] = c
# Divider glow line where audio becomes MIDI.
m = (np.abs(x - 500) < 3) & (y > 200) & (y < 824)
img[m, :3] = img[m, :3] * 0.4 + 0.6

small = img.reshape(S, SS, S, SS, 4).mean(axis=(1, 3))
small[..., :3] = np.where(small[..., 3:4] > 0, small[..., :3] / np.maximum(small[..., 3:4], 1e-6) * small[..., 3:4] / np.maximum(small[..., 3:4], 1e-6), 0)
rgba = (np.clip(small, 0, 1) * 255).astype(np.uint8)


def png(arr):
    raw = b"".join(b"\x00" + arr[r].tobytes() for r in range(arr.shape[0]))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", arr.shape[1], arr.shape[0], 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


out = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon-1024.png"
out.write_bytes(png(rgba))
print(out)
