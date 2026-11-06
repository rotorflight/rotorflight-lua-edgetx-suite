"""Rebuild the approved helicopter layers from one master, masks and annotation patches."""
from pathlib import Path
import argparse
import hashlib
import json
import math
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artwork/helicopter_setup/heli"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--write", action="store_true", help="write rebuilt accepted PNGs for deliberate artwork edits")
args = parser.parse_args()
layout = json.loads((ART / "geometry.json").read_text(encoding="utf-8"))
checks = json.loads((ART / "checks.json").read_text(encoding="utf-8"))
source_bytes = (ART / "master.png").read_bytes()
assert hashlib.sha256(source_bytes).hexdigest() == checks["source_sha256"]
src = Image.open(ART / "master.png").convert("RGBA")
assert list(src.size) == layout["sourceSize"]
raw = np.asarray(src).copy()
mask = Image.new("L", src.size, 0)
ImageDraw.Draw(mask).polygon([tuple(p) for p in layout["tailAssembly"]], fill=255)
tail_area = np.asarray(mask) > 0
body = raw.copy()
body[tail_area, 3] = 0
tail = raw.copy()
tail[~tail_area, 3] = 0
empty_body = body.copy()
for rect in layout["mainBladeMasks"]:
    x0,y0,x1,y1 = rect
    empty_body[y0:y1+1,x0:x1+1,3] = 0
empty_tail = tail.copy()
for rect in layout["tailBladeMasks"]:
    x0,y0,x1,y1 = rect
    empty_tail[y0:y1+1,x0:x1+1,3] = 0
def helicopter(body_pixels, tail_pixels):
    shifted = Image.new("RGBA", src.size)
    shifted.alpha_composite(Image.fromarray(tail_pixels), tuple(layout["tailTranslation"]))
    image = Image.alpha_composite(Image.fromarray(body_pixels), shifted)
    placed = Image.new("RGBA", tuple(layout["canvas"]))
    placed.alpha_composite(image, tuple(layout["placement"]))
    return placed
installed = helicopter(body, tail)
empty = helicopter(empty_body, empty_tail)
rotated = empty.rotate(-layout["rotationClockwiseDegrees"], resample=Image.Resampling.BICUBIC,
    center=tuple(layout["rotationPivot"]), expand=False)
aligned = Image.new("RGBA", tuple(layout["canvas"]))
aligned.alpha_composite(rotated, (0,layout["rotationAlignmentY"]))
angle = math.radians(layout["rotationClockwiseDegrees"])
vector = (470*math.cos(angle),470*math.sin(angle))
assert abs(math.hypot(*vector)-470) < 1e-10
assert abs(math.degrees(math.atan2(vector[1],vector[0]))-20) < 1e-10
assert abs(15-math.degrees(math.atan2(vector[1],vector[0]))) > 1
layers = [
    ("heli-remove-blades",installed,"layer-installed.png"),
    ("heli-level",empty,"layer-empty.png"),
    ("heli-tail-lift",aligned,"layer-rotated-20deg.png")
]
for name,base,reference in layers:
    pixels = np.asarray(base).copy()
    assert np.array_equal(pixels,np.asarray(Image.open(ART/reference).convert("RGBA"))), "Changed common layer: "+name
    patch = np.asarray(Image.open(ART/"annotations"/(name+".png")).convert("RGBA"))
    patch_mask = np.asarray(Image.open(ART/"annotations"/(name+"-mask.png"))) > 0
    pixels[patch_mask] = patch[patch_mask]
    # The master faces right; the wizard draws every helicopter nose left. Mirror the finished
    # image, then turn text regions back so they stay readable.
    if layout.get("mirror"):
        pixels = np.ascontiguousarray(pixels[:, ::-1])
        for x0,y0,x1,y1 in layout.get("readableRegions", {}).get(name, []):
            pixels[y0:y1+1,x0:x1+1] = pixels[y0:y1+1,x0:x1+1][:, ::-1]
    result = Image.fromarray(pixels)
    accepted = ART/"accepted"/(name+".png")
    if args.write:
        result.save(accepted)
    else:
        assert np.array_equal(np.asarray(Image.open(accepted).convert("RGBA")),pixels), "Stale helicopter PNG: "+name
print(json.dumps({"mode":"written" if args.write else "checked","sharedLayers":3,"acceptedImages":3,"rotationDegrees":20,"referenceLength":math.hypot(*vector),"wrongAngleControlRejected":True}))
