#!/usr/bin/env python3
"""The rolling menu's pictures, made from the suite's own icons.

  python bin/dashboard/make_roll_icons.py            writes every picture the manifest names
  python bin/dashboard/make_roll_icons.py --check    exit 1 where one is missing or stale
  python bin/dashboard/make_roll_icons.py --only setup_icon,tools_icon    a few, by name

The firmware cannot tint a picture, so each exists once per colour scheme. The source icons are dark on
an opaque ground: darkness becomes transparency, in the scheme's colour. One size, drawn for 800x480; the
radio scales it at 480 wide.
"""
import argparse
import io
import os
import re
import sys

from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CORE = os.path.join(ROOT, "src", "rfsuite")
OUT = os.path.join(CORE, "widgets", "dashboard", "roll_icons")
SIZE = 32
SCHEMES = {"light": (0x13, 0x15, 0x16), "dark": (0x17, 0x98, 0xE8)}
PAGES = os.path.join(CORE, "app", "pages")


def manifest_motifs():
    """Every picture a row can ask for: name -> source file."""
    text = open(os.path.join(CORE, "app", "manifest.lua"), encoding="utf-8").read()
    motifs = {}
    for match in re.finditer(r'icon = "@pages/([^"]+)\.png"', text):
        rel = match.group(1)
        motifs[rel.replace("/", "_")] = os.path.join(PAGES, *rel.split("/")) + ".png"
    return motifs


def render(source, color):
    image = Image.open(source).convert("RGBA")
    ground = Image.new("RGBA", image.size, (255, 255, 255, 255))
    ground.alpha_composite(image)
    grey = ground.convert("L").resize((SIZE, SIZE), Image.LANCZOS)
    out = Image.new("RGBA", (SIZE, SIZE), color + (0,))
    out.putalpha(grey.point(lambda v: 255 - v))
    buffer = io.BytesIO()
    out.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    motifs = manifest_motifs()
    if args.only:
        wanted = args.only.split(",")
        motifs = {name: motifs[name] for name in wanted}
    bad, written = 0, 0
    for scheme, color in SCHEMES.items():
        folder = os.path.join(OUT, scheme)
        os.makedirs(folder, exist_ok=True)
        for name, source in sorted(motifs.items()):
            path = os.path.join(folder, name + ".png")
            data = render(source, color)
            if args.check:
                if not os.path.exists(path) or open(path, "rb").read() != data:
                    print("STALE " + path)
                    bad += 1
            else:
                open(path, "wb").write(data)
                written += 1
    print("{} motifs, {} written, {} stale".format(len(motifs), written, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
