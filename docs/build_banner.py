#!/usr/bin/env python3
"""Build the RangeGuard project thumbnail / Open Graph banner.

Output: docs/assets/banner.png  (1200x630, standard OG size)

Design (dark-navy design system, matching the slide deck):
  - bg #0f1117
  - shield icon (logo-icon.svg) rasterized at 120x120, centered
  - "RangeGuard"  72px bold  #ffffff   (~20px under the icon)
  - tagline       32px       #94a3b8   (~12px under the name)
  - three badges  16px       #4a5568   centered near the bottom

Calibri is not installed on macOS, so Arial Bold/Regular is used as the
closest geometric sans ("Calibri or similar"). Rasterizes the SVG with
cairosvg; falls back to drawing the shield + bars directly in Pillow.

Run:  python3 docs/build_banner.py
"""

import io
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "assets", "logo-icon.svg")
OUT = os.path.join(HERE, "assets", "banner.png")

W, H = 1200, 630
BG = (15, 17, 23)          # #0f1117
WHITE = (255, 255, 255)    # #ffffff
SLATE = (148, 163, 184)    # #94a3b8
BADGE = (74, 85, 104)      # #4a5568

ICON_PX = 120
GAP_ICON_NAME = 20
GAP_NAME_TAG = 12

NAME = "RangeGuard"
TAGLINE = "Protect your liquidity. Guard your range."
BADGES = "Built on Uniswap v4    ·    Powered by Reactive Network    ·    Deployed on Sepolia"

ARIAL = "/System/Library/Fonts/Supplemental/Arial.ttf"
ARIAL_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def load_font(path, size, fallback_size=None):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(fallback_size or size)


def rasterize_icon(px):
    """SVG -> RGBA PIL image at px*px. cairosvg preferred; Pillow fallback."""
    try:
        import cairosvg

        png_bytes = cairosvg.svg2png(url=SVG, output_width=px, output_height=px)
        return Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    except Exception as e:  # pragma: no cover - fallback path
        print(f"cairosvg unavailable ({e}); drawing shield in Pillow")
        return draw_icon_fallback(px)


def draw_icon_fallback(px):
    """Reproduce logo-icon.svg geometry (64x64 viewBox) at px*px."""
    s = px / 64.0
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Approximate the gradient stroke with its midpoint colour (#CA2D98).
    stroke = (202, 45, 152, 255)
    sw = max(1, round(3 * s))
    pts = [
        (14, 8), (50, 8), (54, 12), (54, 30), (44, 52),
        (32, 58), (20, 52), (10, 30), (10, 12),
    ]
    d.line([(x * s, y * s) for x, y in pts] + [(14 * s, 8 * s)],
           fill=stroke, width=sw, joint="curve")
    green = (0, 211, 149, 255)
    for x, y, w, h in [(20.5, 23, 5.3, 24), (29.3, 13, 5.3, 34), (38.1, 29, 5.3, 18)]:
        d.rounded_rectangle([x * s, y * s, (x + w) * s, (y + h) * s],
                            radius=1 * s, fill=green)
    return img


def text_h(draw, text, font):
    b = draw.textbbox((0, 0), text, font=font, anchor="la")
    return b[3] - b[1]


def main():
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    cx = W // 2

    name_font = load_font(ARIAL_BOLD, 72)
    tag_font = load_font(ARIAL, 32)
    badge_font = load_font(ARIAL, 16)

    name_h = text_h(draw, NAME, name_font)
    tag_h = text_h(draw, TAGLINE, tag_font)

    # Vertically centre the icon+name+tagline trio in the canvas.
    total = ICON_PX + GAP_ICON_NAME + name_h + GAP_NAME_TAG + tag_h
    y = (H - total) // 2

    icon = rasterize_icon(ICON_PX)
    img.paste(icon, (cx - ICON_PX // 2, y), icon)
    y += ICON_PX + GAP_ICON_NAME

    draw.text((cx, y), NAME, font=name_font, fill=WHITE, anchor="ma")
    y += name_h + GAP_NAME_TAG

    draw.text((cx, y), TAGLINE, font=tag_font, fill=SLATE, anchor="ma")

    # Badges pinned near the bottom.
    draw.text((cx, H - 48), BADGES, font=badge_font, fill=BADGE, anchor="mm")

    img.save(OUT, "PNG")
    print(f"wrote {OUT} ({img.width}x{img.height})")


if __name__ == "__main__":
    main()
