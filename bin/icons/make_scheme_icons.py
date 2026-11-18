#!/usr/bin/env python3
"""The suite's pictures in each colour scheme, made from its own icons.

  python bin/icons/make_scheme_icons.py              writes every picture of every set
  python bin/icons/make_scheme_icons.py --check      exit 1 where one is missing, stale or left over
  python bin/icons/make_scheme_icons.py --count      says how many, and writes nothing
  python bin/icons/make_scheme_icons.py --set roll   one set only
  python bin/icons/make_scheme_icons.py --set roll --only setup_icon,tools_icon    a few, by name

The firmware cannot tint a picture, so each exists once per colour scheme. The source icons are dark on
an opaque ground: darkness becomes transparency, in the scheme's colour. The colour is a role of
lib/color_schemes.lua, read from that file, so a value changed there reaches the pictures with the next
run of this script.

A set says which pictures it makes, at what size and where they go:

  roll   the rolling menu's rows (widgets/dashboard/roll_icons/<scheme>/), drawn for 800x480; the radio
         scales them at 480 wide. A row asks by name (widgets/dashboard/menu_tree.lua `iconName`): the
         manifest's own icon with its path joined, else the menu it opens, whose source is the page's own
         icon. The menus the rolling menu opens in the tool with their tiles are not rolled through, so
         their entries need none.
  pages  the tool's tile icons (app/icons/<scheme>/), named by their path under app/pages, so
         app/pages/setup/mixer/icon.png is setup_mixer_icon.png, the name the rolling menu gives it too.
  themes every shipped dashboard theme's pictures (widgets/dashboard/theme_icons/<scheme>/), named by their
         path under widgets/dashboard/themes, so grid/icons/look.png is grid_icons_look.png.
"""
import argparse
import io
import os
import re
import sys

from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CORE = os.path.join(ROOT, "src", "rfsuite")
PAGES = os.path.join(CORE, "app", "pages")
COLOR_SCHEMES = os.path.join(CORE, "lib", "color_schemes.lua")

# The role each scheme draws a picture in: the text colour on the light page, and on the dark page the
# accent where it is a glyph, which reads better on the dark card than the accent of a fill.
ROLES = {"light": "text", "dark": "accentInk"}


def scheme_colors():
    """scheme -> (r, g, b), read from lib/color_schemes.lua."""
    text = open(COLOR_SCHEMES, encoding="utf-8").read()
    colors = {}
    for scheme, role in ROLES.items():
        block = re.search(r"\n  %s = \{(.*?)\n  \}" % scheme, text, flags=re.S)
        if block is None:
            sys.exit("no scheme '%s' in %s" % (scheme, COLOR_SCHEMES))
        value = re.search(r"\b%s\s*=\s*0x([0-9A-Fa-f]{6})\b" % role, block.group(1))
        if value is None:
            sys.exit("no role '%s' in scheme '%s' of %s" % (role, scheme, COLOR_SCHEMES))
        number = int(value.group(1), 16)
        colors[scheme] = ((number >> 16) & 0xFF, (number >> 8) & 0xFF, number & 0xFF)
    return colors


# --- set: roll ---------------------------------------------------------------------------------------

ROLL_OUT = os.path.join(CORE, "widgets", "dashboard", "roll_icons")

# Not rolled through: bin/dashboard/make_menu_list.lua `TILES`.
ROLL_TILES = ("esc_motors_menu", "esc_tools_menu", "helicopter_setup_menu")

# The quick menu's rows, by entry id, and the motif each takes.
ROLL_QUICK = {
    "erase_blackbox": "setup/controls/blackbox/icon",
    "inflight_tuning": "flight_tuning/icon",
    "battery_pick": "setup/power/battery/icon",
    "tool": "settings/icon",
    "flight_log": "tools/flight_log/icon",
    "battery_profile": "setup/power/icon",
}

# A page with no picture of its own takes the one of the part of the menu it is in.
ROLL_FALLBACK = "settings/icon"


def page_icons():
    """menuId -> the page's own icon, as app/pages/init.lua names it."""
    text = open(os.path.join(PAGES, "init.lua"), encoding="utf-8").read()
    return {m.group(1): m.group(2) + "/icon" for m in re.finditer(r'(\w+)\s*=\s*definePage\("([^"]+)"\)', text)}


def roll_motifs():
    """Every picture a row can ask for: name -> source file, and the names that took the fallback."""
    text = open(os.path.join(CORE, "app", "manifest.lua"), encoding="utf-8").read()
    for menu in ROLL_TILES:
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
            rel = ROLL_FALLBACK
        found[menu] = rel
    for entry, rel in ROLL_QUICK.items():
        found[entry] = rel
    return {name: os.path.join(PAGES, *rel.split("/")) + ".png" for name, rel in found.items()}, fell


def roll_set():
    wanted, fell = roll_motifs()
    return {
        "size": 32,
        "pictures": wanted,
        "target": lambda name, scheme: os.path.join(ROLL_OUT, scheme, name + ".png"),
        "folders": lambda scheme: [os.path.join(ROLL_OUT, scheme)],
        "note": "took the fallback: {}".format(fell),
    }


# --- sets: pages and themes ----------------------------------------------------------------------------

# Each set keeps its pictures in one folder per scheme, named by the source's path with "/" joined to "_",
# the rule the rolling menu's names already follow: a folder per picture would double the directories the
# compile pass lists after an install (lib/precompile.lua lists every one).

PAGES_OUT = os.path.join(CORE, "app", "icons")
THEMES = os.path.join(CORE, "widgets", "dashboard", "themes")
# Beside themes/, not in it: every folder in themes/ is taken for a theme.
THEMES_OUT = os.path.join(CORE, "widgets", "dashboard", "theme_icons")

# The tool's pictures that are not a page's own icon.png.
PAGES_EXTRA = ("tools/copy.png", "tools/diagnostics.png", "tools/select_profile.png")


def joined_set(root, out, sources):
    """A set whose pictures are named by their path under root."""
    pictures = {}
    for source in sources:
        rel = os.path.relpath(source, root).replace(os.sep, "/")
        pictures[rel[:-len(".png")].replace("/", "_")] = source
    return {
        "size": 40,
        "pictures": pictures,
        "target": lambda name, scheme: os.path.join(out, scheme, name + ".png"),
        "folders": lambda scheme: [os.path.join(out, scheme)],
        "note": "from {}".format(os.path.relpath(root, ROOT).replace(os.sep, "/")),
    }


def pages_set():
    """The tool's tile icons: every page's icon.png, and the few pictures a tile takes from elsewhere."""
    sources = []
    for folder, _, files in os.walk(PAGES):
        if "icon.png" in files:
            sources.append(os.path.join(folder, "icon.png"))
    sources += [os.path.join(PAGES, *rel.split("/")) for rel in PAGES_EXTRA]
    return joined_set(PAGES, PAGES_OUT, sorted(sources))


def themes_set():
    """Every picture of every shipped dashboard theme: its icon in the theme list and its settings pages'."""
    sources = []
    for folder, _, files in os.walk(THEMES):
        sources += [os.path.join(folder, name) for name in files if name.endswith(".png")]
    return joined_set(THEMES, THEMES_OUT, sorted(sources))


SETS = {"roll": roll_set, "pages": pages_set, "themes": themes_set}


# --- rendering ---------------------------------------------------------------------------------------

def render(source, color, size):
    image = Image.open(source).convert("RGBA")
    ground = Image.new("RGBA", image.size, (255, 255, 255, 255))
    ground.alpha_composite(image)
    grey = ground.convert("L")
    if grey.size != (size, size):
        grey = grey.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), color + (0,))
    out.putalpha(grey.point(lambda v: 255 - v))
    buffer = io.BytesIO()
    out.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def same_picture(path, data):
    """Whether the picture on disk shows what `data` shows. The pixels are compared, not the file's bytes:
    the PNG encoder's output depends on the Pillow and zlib versions, so the same picture can be written
    as different bytes on another machine."""
    with open(path, "rb") as handle:
        old = Image.open(io.BytesIO(handle.read())).convert("RGBA")
    new = Image.open(io.BytesIO(data)).convert("RGBA")
    return old.size == new.size and old.tobytes() == new.tobytes()


def run_set(name, spec, colors, args):
    wanted = spec["pictures"]
    if args.count:
        missing = sorted(source for source in wanted.values() if not os.path.exists(source))
        print("{}: {} pictures in {} schemes = {} files; {}; source missing: {}".format(
            name, len(wanted), len(colors), len(wanted) * len(colors), spec["note"], missing))
        return 1 if missing else 0
    if args.only:
        wanted = {key: wanted[key] for key in args.only.split(",")}
    bad, written, size = 0, 0, 0
    for scheme, color in colors.items():
        targets = set()
        for key, source in sorted(wanted.items()):
            path = spec["target"](key, scheme)
            targets.add(os.path.normcase(os.path.abspath(path)))
            data = render(source, color, spec["size"])
            size += len(data)
            if args.check:
                if not os.path.exists(path) or not same_picture(path, data):
                    print("STALE " + path)
                    bad += 1
            else:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, "wb").write(data)
                written += 1
        if args.check and not args.only:
            for folder in spec["folders"](scheme):
                if not os.path.isdir(folder):
                    continue
                for entry in sorted(os.listdir(folder)):
                    path = os.path.join(folder, entry)
                    if os.path.normcase(os.path.abspath(path)) not in targets:
                        print("LEFT OVER " + path)
                        bad += 1
    print("{}: {} pictures, {} written, {} bad, {} bytes".format(name, len(wanted), written, bad, size))
    return 1 if bad else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--count", action="store_true")
    parser.add_argument("--set", choices=sorted(SETS), help="one set only")
    parser.add_argument("--only", default="", help="names within the one set given by --set")
    args = parser.parse_args()
    if args.only and not args.set:
        parser.error("--only needs --set")
    colors = scheme_colors()
    names = [args.set] if args.set else sorted(SETS)
    result = 0
    for name in names:
        result |= run_set(name, SETS[name](), colors, args)
    return result


if __name__ == "__main__":
    sys.exit(main())
