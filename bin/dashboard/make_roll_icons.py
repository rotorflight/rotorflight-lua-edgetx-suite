#!/usr/bin/env python3
"""The rolling menu's pictures, made from the suite's own icons.

  python bin/dashboard/make_roll_icons.py            writes every picture a row can ask for
  python bin/dashboard/make_roll_icons.py --check    exit 1 where one is missing, stale or left over
  python bin/dashboard/make_roll_icons.py --count    says how many, and writes nothing
  python bin/dashboard/make_roll_icons.py --only setup_icon,tools_icon    a few, by name

The firmware cannot tint a picture, so each exists once per colour scheme. The source icons are dark on
an opaque ground: darkness becomes transparency, in the scheme's colour. One size, drawn for 800x480; the
radio scales it at 480 wide.

A row asks by name (widgets/dashboard/menu_tree.lua `iconName`): the manifest's own icon with its path
joined, else the menu it opens, whose source is the page's own icon. The menus the rolling menu opens in
the tool with their tiles are not rolled through, so their entries need none.
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
PAGES = os.path.join(CORE, "app", "pages")
SIZE = 32
SCHEMES = {"light": (0x13, 0x15, 0x16), "dark": (0x17, 0x98, 0xE8)}

# Not rolled through: bin/dashboard/make_menu_list.lua `TILES`.
TILES = ("esc_motors_menu", "esc_tools_menu", "helicopter_setup_menu")

# The quick menu's rows, by entry id, and the motif each takes.
QUICK = {
    "erase_blackbox": "setup/controls/blackbox/icon",
    "inflight_tuning": "flight_tuning/icon",
    "battery_pick": "setup/power/battery/icon",
    "tool": "settings/icon",
    "flight_log": "tools/flight_log/icon",
    "battery_profile": "setup/power/icon",
}

# A page with no picture of its own takes the one of the part of the menu it is in.
FALLBACK = "settings/icon"


def page_icons():
    """menuId -> the page's own icon, as app/pages/init.lua names it."""
    text = open(os.path.join(PAGES, "init.lua"), encoding="utf-8").read()
    return {m.group(1): m.group(2) + "/icon" for m in re.finditer(r'(\w+)\s*=\s*definePage\("([^"]+)"\)', text)}


def motifs():
    """Every picture a row can ask for: name -> source file, and the names that took the fallback."""
    text = open(os.path.join(CORE, "app", "manifest.lua"), encoding="utf-8").read()
    for menu in TILES:
        # A menu's block ends at the first line that closes it at its own indent.
        text = re.sub(r"\n    %s = \{.*?\n    \},?" % menu, "\n", text, flags=re.S)
    pages = page_icons()
    found, fell = {}, []
    # An entry can run over several lines; a comment is no entry.
    text = re.sub(r"^\s*--.*$", "", text, flags=re.M)
    for line in re.findall(r'\{ id = "\w+",(?:[^{}]|\{[^{}]*\})*?menuId = "\w+"(?:[^{}]|\{[^{}]*\})*?\}', text, flags=re.S):
        icon = re.search(r'icon = "@pages/([^"]+)\.png"', line)
        if icon:
            found[icon.group(1).replace("/", "_")] = icon.group(1)
            continue
        menu = re.search(r'menuId = "(\w+)"', line).group(1)
        rel = pages.get(menu)
        if rel is None or not os.path.exists(os.path.join(PAGES, *rel.split("/")) + ".png"):
            fell.append(menu)
            rel = FALLBACK
        found[menu] = rel
    for entry, rel in QUICK.items():
        found[entry] = rel
    return {name: os.path.join(PAGES, *rel.split("/")) + ".png" for name, rel in found.items()}, fell


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
    parser.add_argument("--count", action="store_true")
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    wanted, fell = motifs()
    if args.count:
        missing = [source for source in wanted.values() if not os.path.exists(source)]
        print("{} pictures in {} schemes = {} files; took the fallback: {}; source missing: {}".format(
            len(wanted), len(SCHEMES), len(wanted) * len(SCHEMES), fell, missing))
        return 1 if missing else 0
    if args.only:
        wanted = {name: wanted[name] for name in args.only.split(",")}
    bad, written, size = 0, 0, 0
    for scheme, color in SCHEMES.items():
        folder = os.path.join(OUT, scheme)
        os.makedirs(folder, exist_ok=True)
        for name, source in sorted(wanted.items()):
            path = os.path.join(folder, name + ".png")
            data = render(source, color)
            size += len(data)
            if args.check:
                if not os.path.exists(path) or open(path, "rb").read() != data:
                    print("STALE " + path)
                    bad += 1
            else:
                open(path, "wb").write(data)
                written += 1
        if args.check and not args.only:
            for name in sorted(os.listdir(folder)):
                if name[:-4] not in wanted:
                    print("LEFT OVER " + os.path.join(folder, name))
                    bad += 1
    print("{} pictures, {} written, {} bad, {} bytes".format(len(wanted), written, bad, size))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
