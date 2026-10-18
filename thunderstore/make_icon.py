"""Placeholder Antelytics Thunderstore icon: dark rounded tile (viewer --bg-panel),
a white playing card, and an indigo (viewer --accent) run-history line chart."""
import sys
from PIL import Image, ImageDraw

OUT = sys.argv[1]
S = 4                      # supersample for antialiasing
N = 256 * S
BG, CARD, ACCENT, INK = (26, 26, 30, 255), (248, 248, 251, 255), (99, 102, 241, 255), (13, 13, 15, 255)

im = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
d.rounded_rectangle((0, 0, N - 1, N - 1), radius=44 * S, fill=BG)

# Card
cx0, cy0, cx1, cy1 = 60 * S, 36 * S, 196 * S, 220 * S
d.rounded_rectangle((cx0, cy0, cx1, cy1), radius=14 * S, fill=CARD)

# Corner pips (spade-ish diamonds)
def pip(x, y, r, fill):
    d.polygon([(x, y - r), (x + r * 0.7, y), (x, y + r), (x - r * 0.7, y)], fill=fill)
pip(cx0 + 16 * S, cy0 + 18 * S, 7 * S, INK)
pip(cx1 - 16 * S, cy1 - 18 * S, 7 * S, INK)

# Rising line chart inside the card
pts = [(0.0, 0.78), (0.2, 0.62), (0.4, 0.70), (0.6, 0.42), (0.8, 0.50), (1.0, 0.18)]
px0, px1 = cx0 + 24 * S, cx1 - 24 * S
py0, py1 = cy0 + 40 * S, cy1 - 40 * S
P = [(px0 + (px1 - px0) * x, py0 + (py1 - py0) * y) for x, y in pts]
d.line(P, fill=ACCENT, width=9 * S, joint="curve")
for x, y in P:
    r = 9 * S
    d.ellipse((x - r, y - r, x + r, y + r), fill=ACCENT)
    r2 = 4 * S
    d.ellipse((x - r2, y - r2, x + r2, y + r2), fill=CARD)

im = im.resize((256, 256), Image.LANCZOS)
im.save(OUT, "PNG", optimize=True)
print(OUT, im.size, im.mode)
