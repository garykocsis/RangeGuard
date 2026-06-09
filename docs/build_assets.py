#!/usr/bin/env python3
"""Rasterize the deck's SVG logos to PNGs for python-pptx embedding.

python-pptx cannot embed SVG, and the only local renderer (macOS qlmanage)
composites SVGs on an opaque WHITE background. Every logo in the deck is placed
on the flat #0f1117 slide background, so we render each SVG with a matching navy
background rect (seamless on-slide) and crop away qlmanage's white padding.

Output: docs/assets/png/<name>.png   (run from anywhere; paths are absolute)
"""
import os
import re
import subprocess
import tempfile
from PIL import Image

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")
PNG_DIR = os.path.join(ASSETS, "png")
SLIDE_BG = "#0f1117"
RENDER_PX = 2000  # longest side; generous for crisp downscaling in the deck

# name -> (source svg, background color, keep_left fraction)
# keep_left: after cropping to content, keep only the leftmost fraction of width.
# The Reactive docs asset is a "reactive | Dev" lockup; we keep just the "reactive"
# icon+wordmark (drop the "| Dev" suffix) for a clean "Powered by" partner badge.
#
# Only the shield ICON + partner logos are rasterized for embedding. The "RangeGuard"
# wordmark and tagline are drawn as NATIVE pptx Calibri text on the slides (crisper, and
# avoids a faint full-width raster-edge artifact under downscaled tagline text). The full
# logo-full.svg / logo-standalone.svg remain as standalone brand assets in docs/assets/.
ASSETS_TO_RENDER = {
    "logo-icon":        ("logo-icon.svg",        SLIDE_BG, 1.0),
    "uniswap-logo":     ("uniswap-logo.svg",     SLIDE_BG, 1.0),
    "reactive-logo":    ("reactive-logo.svg",    SLIDE_BG, 0.685),
}


def inject_bg(svg_text, color):
    """Insert an opaque background rect right after the opening <svg ...> tag."""
    m = re.search(r"<svg\b[^>]*>", svg_text)
    if not m:
        raise ValueError("no <svg> tag")
    rect = f'<rect x="-9999" y="-9999" width="99999" height="99999" fill="{color}"/>'
    i = m.end()
    return svg_text[:i] + rect + svg_text[i:]


def render(name, src, bg, keep_left=1.0):
    src_path = os.path.join(ASSETS, src)
    with open(src_path) as f:
        svg = f.read()
    svg = inject_bg(svg, bg)
    with tempfile.TemporaryDirectory() as td:
        tmp_svg = os.path.join(td, f"{name}.svg")
        with open(tmp_svg, "w") as f:
            f.write(svg)
        subprocess.run(["qlmanage", "-t", "-s", str(RENDER_PX), "-o", td, tmp_svg],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        out_png = os.path.join(td, f"{name}.svg.png")
        im = Image.open(out_png).convert("RGB")
        # crop away qlmanage's pure-white padding -> tight content rect (all navy/logo)
        px = im.load()
        W, H = im.size
        white = (255, 255, 255)
        # scan for non-white bounds
        from PIL import ImageChops
        bg_img = Image.new("RGB", im.size, white)
        diff = ImageChops.difference(im, bg_img)
        bbox = diff.getbbox()
        if bbox:
            im = im.crop(bbox)
        if keep_left < 1.0:
            w, h = im.size
            im = im.crop((0, 0, int(w * keep_left), h))
            # re-trim any navy gap left at the new right edge
            from PIL import ImageChops as _IC
            bg2 = Image.new("RGB", im.size, (255, 255, 255))
            b2 = _IC.difference(im, bg2).getbbox()
            if b2:
                im = im.crop(b2)
        # Key the navy fill to transparent so the PNG has NO opaque rectangle/edge seam
        # on the slide. Background pixels are exactly SLIDE_BG; logo colors are bright and
        # never collide with it, so an exact-match key is clean (anti-aliased silhouette
        # pixels stay and blend correctly against the same navy slide).
        nb = tuple(int(bg.lstrip("#")[k:k+2], 16) for k in (0, 2, 4))
        rgba = im.convert("RGBA")
        datas = rgba.getdata()
        keyed = [(r, g, b, 0) if (r, g, b) == nb else (r, g, b, a)
                 for (r, g, b, a) in datas]
        rgba.putdata(keyed)
        im = rgba
        # Add a small transparent margin so the image boundary never sits exactly on a
        # glyph edge — otherwise a full-width text baseline at the crop edge resamples to a
        # faint 1px line on the slide. Symmetric, so centered placement is unaffected.
        from PIL import ImageOps
        m = max(8, round(0.012 * max(im.size)))
        im = ImageOps.expand(im, border=m, fill=(0, 0, 0, 0))
        os.makedirs(PNG_DIR, exist_ok=True)
        im.save(os.path.join(PNG_DIR, f"{name}.png"))
        w, h = im.size
        print(f"{name:18s} {w}x{h}  aspect={w/h:.3f}")
        return w / h


if __name__ == "__main__":
    aspects = {}
    for name, (src, bg, keep_left) in ASSETS_TO_RENDER.items():
        aspects[name] = render(name, src, bg, keep_left)
    print("\naspects =", {k: round(v, 4) for k, v in aspects.items()})
