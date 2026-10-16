"""Generate the default topographic contour-line SVG (apc_light/assets/topo.svg).

A smooth random height field (sum of Gaussian hills/valleys) is traced with
marching squares at evenly spaced levels; the segments are joined into
polylines and written as thin white strokes on a transparent background.
The app tints and fades it (Inspector ▸ Colors ▸ Background).

    python tools/make_topo.py [out.svg] [seed]
"""

from __future__ import annotations

import math
import random
import sys
from collections import defaultdict
from pathlib import Path

W, H = 1600, 1000       # SVG units (rendered with "cover" scaling)
GRID = 4                # sample spacing
LEVELS = 26


def field(rng: random.Random):
    blobs = []
    for _ in range(26):
        blobs.append((rng.uniform(-200, W + 200), rng.uniform(-200, H + 200),
                      rng.uniform(140, 420), rng.uniform(-1.0, 1.0)))
    nx, ny = W // GRID + 1, H // GRID + 1
    z = [[0.0] * nx for _ in range(ny)]
    for j in range(ny):
        y = j * GRID
        row = z[j]
        for i in range(nx):
            x = i * GRID
            v = 0.0
            for bx, by, r, a in blobs:
                dx, dy = x - bx, y - by
                v += a * math.exp(-(dx * dx + dy * dy) / (2 * r * r))
            # gentle ridges so lines aren't all concentric rings
            v += 0.12 * math.sin(x / 210.0 + y / 330.0) + 0.08 * math.sin(y / 150.0 - x / 480.0)
            row[i] = v
    return z, nx, ny


def march(z, nx, ny, level):
    """Marching squares -> list of segments ((x1,y1),(x2,y2))."""
    segs = []

    def interp(p1, p2, v1, v2):
        t = 0.5 if v1 == v2 else (level - v1) / (v2 - v1)
        return (p1[0] + (p2[0] - p1[0]) * t, p1[1] + (p2[1] - p1[1]) * t)

    for j in range(ny - 1):
        for i in range(nx - 1):
            v = (z[j][i], z[j][i + 1], z[j + 1][i + 1], z[j + 1][i])
            idx = sum(1 << k for k in range(4) if v[k] > level)
            if idx in (0, 15):
                continue
            x0, y0, x1, y1 = i * GRID, j * GRID, (i + 1) * GRID, (j + 1) * GRID
            pts = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
            e = {
                0: lambda: interp(pts[0], pts[1], v[0], v[1]),
                1: lambda: interp(pts[1], pts[2], v[1], v[2]),
                2: lambda: interp(pts[2], pts[3], v[2], v[3]),
                3: lambda: interp(pts[3], pts[0], v[3], v[0]),
            }
            table = {1: [(3, 0)], 2: [(0, 1)], 3: [(3, 1)], 4: [(1, 2)], 5: [(3, 0), (1, 2)], 6: [(0, 2)],
                     7: [(3, 2)], 8: [(2, 3)], 9: [(0, 2)], 10: [(0, 1), (2, 3)], 11: [(1, 2)], 12: [(1, 3)],
                     13: [(0, 1)], 14: [(3, 0)]}
            for a, b in table[idx]:
                segs.append((e[a](), e[b]()))
    return segs


def join(segs):
    """Chain segments sharing endpoints into polylines."""
    key = lambda p: (round(p[0], 2), round(p[1], 2))  # noqa: E731
    adj = defaultdict(list)
    for n, (a, b) in enumerate(segs):
        adj[key(a)].append(n)
        adj[key(b)].append(n)
    used = [False] * len(segs)
    lines = []
    for n in range(len(segs)):
        if used[n]:
            continue
        used[n] = True
        a, b = segs[n]
        line = [a, b]
        for forward in (True, False):
            while True:
                end = line[-1] if forward else line[0]
                nxt = next((m for m in adj[key(end)] if not used[m]), None)
                if nxt is None:
                    break
                used[nxt] = True
                p, q = segs[nxt]
                other = q if key(p) == key(end) else p
                if forward:
                    line.append(other)
                else:
                    line.insert(0, other)
        if len(line) > 3:
            lines.append(line)
    return lines


def simplify(line, step=2):
    return line[::step] + ([line[-1]] if (len(line) - 1) % step else [])


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parents[1] / "apc_light" / "assets" / "topo.svg"
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 11
    rng = random.Random(seed)
    z, nx, ny = field(rng)
    lo = min(min(r) for r in z)
    hi = max(max(r) for r in z)
    paths = []
    for k in range(1, LEVELS):
        level = lo + (hi - lo) * k / LEVELS
        major = k % 5 == 0
        for line in join(march(z, nx, ny, level)):
            pts = simplify(line)
            d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
            width = ' stroke-width="2"' if major else ""
            paths.append(f'<path d="{d}"{width}/>')
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">\n'
           f'<g fill="none" stroke="#ffffff" stroke-width="1.1" stroke-linejoin="round" stroke-linecap="round">\n'
           + "\n".join(paths)
           + "\n</g>\n</svg>\n")
    out.write_text(svg, "utf-8")
    print(f"{out}  {len(paths)} contours  {out.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
