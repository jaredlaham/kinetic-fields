"""Build the app icon from the artwork in apc_light/assets/source/icon_source.webp.

The source art has its "transparent" checkerboard baked into the pixels, so this
script:

1. cuts the icon out (flood-fills the neutral light-grey background from the
   image border, keeps the largest shape, fills holes),
2. smooths and anti-aliases the silhouette and pulls the edge in slightly so
   no checkerboard fringe survives,
3. fits it to Apple's macOS icon grid (824 px artwork on a 1024 px canvas)
   with a soft drop shadow,
4. renders every iconset size (16-1024 px) with extra sharpening for the
   small ones, and writes AppIcon.icns plus the PNGs the app uses at runtime.

    python tools/make_icon.py            # writes into apc_light/assets/

Requires: pip install pillow numpy scipy  (only needed to regenerate the icon).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "apc_light" / "assets" / "source" / "icon_source.webp"
OUT = ROOT / "apc_light" / "assets"

CANVAS = 1024
ART = 824          # Apple macOS icon grid: 824x824 artwork centred in 1024x1024
SHADOW_BLUR = 18
SHADOW_OFFSET = 10
SHADOW_ALPHA = 0.32

ICONSET = [16, 32, 64, 128, 256, 512, 1024]


def cut_out(img: Image.Image) -> Image.Image:
    rgb = np.asarray(img.convert("RGB")).astype(np.int16)
    chroma = rgb.max(2) - rgb.min(2)
    background_like = (chroma < 22) & (rgb.min(2) > 150)   # white/grey checkerboard
    labels, _ = ndi.label(background_like)
    border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    background = np.isin(labels, border[border > 0])
    fg = ndi.binary_fill_holes(~background)
    labels, n = ndi.label(fg)
    sizes = ndi.sum(fg, labels, range(1, n + 1))
    fg = labels == (int(np.argmax(sizes)) + 1)

    # Smooth the silhouette (removes stair-steps / small notches), then pull the
    # edge in by ~2 px so the light fringe from the checkerboard disappears.
    soft = ndi.gaussian_filter(fg.astype(np.float32), 3.0)
    fg = soft > 0.5
    fg = ndi.binary_erosion(fg, iterations=2)
    alpha = ndi.gaussian_filter(fg.astype(np.float32), 0.8)  # anti-aliased edge
    alpha = np.clip((alpha - 0.5) * 2.2 + 0.5, 0, 1)

    rgba = np.dstack([rgb.astype(np.uint8), (alpha * 255).astype(np.uint8)])
    out = Image.fromarray(rgba, "RGBA")
    return out.crop(out.getbbox())


def compose(art: Image.Image) -> Image.Image:
    w, h = art.size
    scale = ART / max(w, h)
    art = art.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - art.width) // 2
    y = (CANVAS - art.height) // 2 - 4   # optical centre: leave room for the shadow
    shadow_alpha = art.getchannel("A").point(lambda v: int(v * SHADOW_ALPHA))
    shadow = Image.new("RGBA", art.size, (0, 0, 0, 255))
    shadow.putalpha(shadow_alpha)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(shadow, (x, y + SHADOW_OFFSET), shadow)
    layer = layer.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    canvas = Image.alpha_composite(canvas, layer)
    canvas.alpha_composite(art, (x, y))
    return canvas


def sized(master: Image.Image, px: int) -> Image.Image:
    im = master.resize((px, px), Image.LANCZOS)
    if px <= 64:
        im = im.filter(ImageFilter.UnsharpMask(radius=0.6, percent=90, threshold=1))
    elif px <= 256:
        im = im.filter(ImageFilter.UnsharpMask(radius=0.8, percent=50, threshold=2))
    return im


def main() -> int:
    if not SRC.exists():
        print(f"missing {SRC}", file=sys.stderr)
        return 1
    master = compose(cut_out(Image.open(SRC)))
    OUT.mkdir(parents=True, exist_ok=True)
    master.save(OUT / "AppIcon.png", optimize=True)
    sized(master, 256).save(OUT / "AppIcon-256.png", optimize=True)  # window/Dock icon from source
    # .icns with every size macOS looks for (Pillow picks sizes from the list).
    icns_sizes = {px: sized(master, px) for px in ICONSET}
    icns_sizes[1024].save(OUT / "AppIcon.icns", format="ICNS",
                          append_images=[icns_sizes[p] for p in ICONSET if p != 1024])
    for f in ("AppIcon.png", "AppIcon-256.png", "AppIcon.icns"):
        print(f"{OUT / f}  {(OUT / f).stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
