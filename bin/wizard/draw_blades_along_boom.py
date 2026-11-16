"""Draw the blade-pitch intro picture: the helicopter from above, nose left, the main blades turned
along the tail boom.

The grey dashed blades stand where the blades may be now, the blue ones where they go, and a curved
arrow joins them. One set per colour scheme and a small set for the 480-pixel-wide screens, in the
sizes the other wizard pictures have (220x160 and 154x112), with the colours of
src/rfsuite/lib/color_schemes.lua. Drawn four times larger and scaled down for smooth edges.

  python bin/wizard/draw_blades_along_boom.py          # writes the four PNG files
  python bin/wizard/draw_blades_along_boom.py --check  # exit 1 when a written file differs
"""
import argparse
import io
import math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
GFX = ROOT / 'src/rfsuite/app/pages/helicopter_setup/gfx'
NAME = 'heli-top-blades-boom.png'


def rgb(value):
    return ((value >> 16) & 255, (value >> 8) & 255, value & 255)


# accent and accentInk are the scheme's (lib/color_schemes.lua); the body tones follow the side views.
SCHEMES = {
    'light': dict(body=(52, 58, 64), fill=(214, 219, 224), glass=(170, 200, 225), dash=(186, 192, 198),
                  accent=rgb(0x007BC7), ink=rgb(0x0065A3)),
    'dark': dict(body=(172, 179, 185), fill=(64, 70, 77), glass=(58, 92, 124), dash=(96, 103, 110),
                 accent=rgb(0x1798E8), ink=rgb(0x61B9EF)),
}


def draw(width, height, colors):
    """Nose up first (the boom runs down), then turned a quarter left so the nose points left."""
    up_w, up_h = height, width
    s4 = 4
    scale = min((up_w - 6) / 172.0, (up_h - 6) / 262.0) * s4
    image = Image.new('RGBA', (up_w * s4, up_h * s4), (0, 0, 0, 0))
    d = ImageDraw.Draw(image, 'RGBA')
    cx, cy = up_w * s4 / 2, (3 + 116 * scale / s4) * s4

    def p(x, y):
        return (cx + x * scale, cy + y * scale)

    line = max(1, round(2 * scale))
    body, fill = colors['body'], colors['fill']
    # tail boom (tapered), fin and tail rotor
    d.polygon([p(-6, 30), p(6, 30), p(3, 128), p(-3, 128)], fill=fill, outline=body, width=line)
    d.polygon([p(-3, 118), p(-16, 138), p(-3, 134)], fill=fill, outline=body, width=line)
    d.rounded_rectangle([p(4, 112), p(10, 146)], radius=2 * scale, fill=body)
    # fuselage with the canopy at the nose, and the skids
    d.ellipse([p(-30, -52), p(30, 44)], fill=fill, outline=body, width=line)
    d.ellipse([p(-20, -48), p(20, -6)], fill=colors['glass'], outline=body, width=max(1, line // 2))
    for sx in (-38, 38):
        d.rounded_rectangle([p(sx - 3, -40), p(sx + 3, 36)], radius=3 * scale, fill=body)

    def blade(angle, length, color, outline=None, dashed=False):
        r = math.radians(angle)
        ux, uy = math.sin(r), -math.cos(r)
        nx, ny = -uy, ux
        root, wr, wt = 10, 6, 4
        if dashed:
            for t0 in range(root, length, 14):
                t1 = min(t0 + 8, length)
                d.line([p(ux * t0, uy * t0), p(ux * t1, uy * t1)], fill=color, width=round(10 * scale))
            return
        d.polygon([p(ux * root + nx * wr, uy * root + ny * wr), p(ux * length + nx * wt, uy * length + ny * wt),
                   p(ux * length - nx * wt, uy * length - ny * wt), p(ux * root - nx * wr, uy * root - ny * wr)],
                  fill=color, outline=outline, width=max(1, line // 2))
        d.ellipse([p(ux * length - wt, uy * length - wt), p(ux * length + wt, uy * length + wt)], fill=color)

    # where the blades may stand now, and where they go: along the boom
    blade(50, 104, colors['dash'], dashed=True)
    blade(230, 104, colors['dash'], dashed=True)
    blade(0, 112, colors['accent'], outline=colors['ink'])
    blade(180, 112, colors['accent'], outline=colors['ink'])
    d.ellipse([p(-11, -11), p(11, 11)], fill=body)
    d.ellipse([p(-4, -4), p(4, 4)], fill=fill)
    # the curved arrow from the grey blade to the blue one
    rr = 80
    d.arc([p(-rr, -rr), p(rr, rr)], start=-90 + 12, end=-90 + 46, fill=colors['ink'], width=round(4 * scale))
    a = math.radians(14)
    tx, ty = math.sin(a) * rr, -math.cos(a) * rr
    d.polygon([p(tx - 8, ty - 7), p(tx + 3, ty + 8), p(tx - 12, ty + 9)], fill=colors['ink'])
    small = image.resize((up_w, up_h), Image.LANCZOS)
    return small.rotate(90, expand=True)


def outputs():
    for folder, scheme, size in (('light', 'light', (220, 160)), ('dark', 'dark', (220, 160)),
                                 ('small_light', 'light', (154, 112)), ('small', 'dark', (154, 112))):
        yield GFX / folder / NAME, draw(size[0], size[1], SCHEMES[scheme])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='compare with the written files instead of writing')
    args = parser.parse_args()
    differing = 0
    for path, image in outputs():
        buffer = io.BytesIO()
        image.save(buffer, format='PNG', optimize=True)
        data = buffer.getvalue()
        if args.check:
            same = path.exists() and Image.open(path).convert('RGBA').tobytes() == image.convert('RGBA').tobytes()
            print(('same    ' if same else 'DIFFERS ') + str(path.relative_to(ROOT)))
            differing += 0 if same else 1
        else:
            path.write_bytes(data)
            print('wrote ' + str(path.relative_to(ROOT)) + ' %dx%d' % image.size)
    return 1 if differing else 0


if __name__ == '__main__':
    raise SystemExit(main())
