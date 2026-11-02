"""Draw the app icon: a film strip on black, one frame lit safelight amber.

    python ios/tools/make_icon.py

Writes ios/SpektraLabMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
Its own icon, not SpektraLab's: the name and icon are trademarks (top-level
README, "Trademark"). Drawn at 2x and scaled down for clean edges; opaque,
since iOS rounds the corners itself.
"""

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # working size; the icon is half
out = Path(__file__).resolve().parents[1] / "SpektraLabMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png"


def radial(size, inner, outer, center=(0.5, 0.5), radius=0.75):
    """A radial gradient from `inner` at `center` to `outer` at `radius` (fractions of size)."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    cx, cy, r = center[0] * w, center[1] * h, radius * max(w, h)
    for y in range(h):
        for x in range(w):
            t = min(1.0, math.hypot(x - cx, y - cy) / r)
            t = t * t * (3 - 2 * t)  # smoothstep
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(inner, outer))
    return img


# Background: near black with a faint warm glow, like a darkroom under the safelight.
icon = radial((S // 8, S // 8), (34, 22, 14), (6, 6, 7), radius=0.7).resize((S, S), Image.BICUBIC)
draw = ImageDraw.Draw(icon)

# The strip: edge to edge, a little above centre of the optical middle.
strip_h = 1020
top = (S - strip_h) // 2
draw.rectangle([0, top, S, top + strip_h], fill=(22, 21, 20))

# Sprocket holes along both edges.
hole_w, hole_h, pitch = 92, 128, 196
margin = 64
for row_y in (top + margin, top + strip_h - margin - hole_h):
    x = -pitch // 2
    while x < S:
        draw.rounded_rectangle([x, row_y, x + hole_w, row_y + hole_h], radius=22, fill=(5, 5, 6))
        x += pitch

# The frames: dark neighbours either side, the middle one lit.
frame_h = strip_h - 2 * (margin + hole_h) - 2 * 70
frame_y = top + margin + hole_h + 70
frame_w = 1180
gap = 120
cx = S // 2
for i in (-1, 1):
    x0 = cx + i * (frame_w + gap) - frame_w // 2
    draw.rounded_rectangle([x0, frame_y, x0 + frame_w, frame_y + frame_h], radius=36, fill=(40, 30, 22))

lit = radial((frame_w // 4, frame_h // 4), (255, 206, 120), (178, 92, 28), center=(0.42, 0.4), radius=0.85)
lit = lit.resize((frame_w, frame_h), Image.BICUBIC)
# A little grain on the lit frame.
noise = Image.effect_noise((frame_w, frame_h), 24).filter(ImageFilter.GaussianBlur(1.2))
lit = Image.blend(lit, Image.merge("RGB", [noise] * 3), 0.06)
mask = Image.new("L", (frame_w, frame_h), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, frame_w, frame_h], radius=36, fill=255)
x0 = cx - frame_w // 2
icon.paste(lit, (x0, frame_y), mask)

# Its glow on the strip around it, then the frame again, crisp, on top.
glow = Image.new("RGB", (S, S), (0, 0, 0))
ImageDraw.Draw(glow).rounded_rectangle([x0, frame_y, x0 + frame_w, frame_y + frame_h], radius=36, fill=(120, 64, 18))
glow = glow.filter(ImageFilter.GaussianBlur(70))
icon = ImageChops.add(icon, glow.point(lambda v: v // 2))
icon.paste(lit, (x0, frame_y), mask)

out.parent.mkdir(parents=True, exist_ok=True)
icon.resize((1024, 1024), Image.LANCZOS).convert("RGB").save(out)
print(out)
