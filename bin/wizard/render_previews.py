"""Approximate scene previews from verify.lua --export; no native UI or simulator.

Requires Pillow. Example:
  lua5.3 bin/wizard/verify.lua --export scenes.json
  python bin/wizard/render_previews.py scenes.json docs/images/helicopter_setup
"""
import argparse
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

FONT_PATHS = (Path('C:/Windows/Fonts/arial.ttf'), Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'))
FONT = next((p for p in FONT_PATHS if p.exists()), None)
SRC = Path(__file__).resolve().parents[2] / 'src' / 'rfsuite'


def font(size):
    return ImageFont.truetype(str(FONT), size) if FONT else ImageFont.load_default(size=size)


def wrap(draw, text, face, width):
    lines = []
    for paragraph in str(text).splitlines():
        current = ''
        for word in paragraph.split():
            candidate = (current + ' ' + word).strip()
            if current and draw.textlength(candidate, font=face) > width:
                lines.append(current)
                current = word
            else:
                current = candidate
        lines.append(current)
    return lines


def color(value, default):
    if not isinstance(value, int):
        return default
    return {1: "#000000", 2: "#ffffff", 3: "#0c3f66", 4: "#125e99"}.get(value, f"#{value:06x}")


def render(scene):
    width, height = scene['width'], scene['height']
    image = Image.new('RGB', (width, height), '#edf1f5')
    draw = ImageDraw.Draw(image)
    large = width >= 700
    size = 20 if large else 13 if width >= 480 else 12
    for item in scene['children']:
        if item.get('visible') is False:
            continue
        kind = item['type']
        x, y, w, h = (item.get(k, 0) for k in ('x', 'y', 'w', 'h'))
        x, y = item.get('pos', (x, y))
        ink = color(item.get('color'), '#26394c')
        if kind == 'rectangle':
            if item.get('filled'):
                draw.rectangle((x,y,x+w,y+h), fill=ink)
            else:
                draw.rectangle((x,y,x+w,y+h), outline=ink, width=item.get('thickness', 2))
        elif kind == 'line':
            draw.line([tuple(p) for p in item['pts']], fill=ink, width=item.get('thickness', 2), joint='curve')
        elif kind == 'image':
            # Zoomed to fit its frame, keeping the aspect, as EdgeTX does for a Lua image.
            rel = str(item.get('file', '')).removeprefix('/SCRIPTS/TOOLS/rfsuite-core/')
            picture = Image.open(SRC / rel).convert('RGBA')
            zoom = min(w / picture.width, h / picture.height)
            picture = picture.resize((max(1, round(picture.width * zoom)), max(1, round(picture.height * zoom))),
                                     Image.Resampling.BILINEAR)
            image.paste(picture, (x + (w - picture.width) // 2, y + (h - picture.height) // 2), picture)
        elif kind == 'label':
            face = font((26 if large else 17) if item.get('font') == 1 else size)
            text = str(item.get('text', ''))
            lines = wrap(draw, text, face, w)
            line_h = face.size + 3
            if h:
                lines = lines[:max(1, int(h / line_h))]
            for n,line in enumerate(lines):
                draw.text((x,y+n*line_h),line,font=face,fill=ink)
        elif kind in ('button','momentaryButton','choice','numberEdit'):
            draw.rounded_rectangle((x,y,x+w,y+h),radius=4,
                                   fill=color(item.get('color'), '#fff'),outline='#34404b',width=1)
            face = font(size)
            text = item.get('text')
            if text is None:
                value = item.get('get', '')
                if kind == 'choice':
                    values = item['values']
                    text = values[int(value)-1] if isinstance(value,(int,float)) and 1 <= value <= len(values) else '?'
                else:
                    text = item.get('display',str(value))
            while draw.textlength(str(text),font=face) > w-12 and size > 8:
                size -= 1
                face = font(size)
            draw.text((x+w/2,y+h/2),str(text),anchor='mm',font=face,fill=color(item.get('textColor'), '#26394c'))
            if kind == 'choice':
                draw.polygon(((x+w-12,y+h/2-2),(x+w-6,y+h/2-2),(x+w-9,y+h/2+2)),fill='#74889b')
            size = 20 if large else 13 if width >= 480 else 12
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenes',type=Path)
    parser.add_argument('output',type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    scenes = json.loads(args.scenes.read_text(encoding="utf-8"))
    pictures = animations = 0
    for width,height,label in ((320,240,'narrow'),(480,272,'small'),(800,480,'large')):
        selected = [s for s in scenes if s['width']==width and s['height']==height and 'motion' not in s]
        names=set()
        for s in selected:
            suffix = f'-task-{s["task"]}' if 'task' in s else ''
            name=f'{s["step"]:02d}-{label}{suffix}.png'
            assert name not in names, f'Duplicate preview target: {name}'
            names.add(name)
            render(s).save(args.output/name)
            pictures += 1
        selected = [s for s in selected if 'task' not in s]
        selected.sort(key=lambda s:s['step'])
        scale = 0.6 if label=='large' else 1
        tile_w,tile_h = round(width*scale),round(height*scale)
        sheet = Image.new('RGB',(tile_w*3+40,(tile_h+32)*math.ceil(len(selected)/3)+62),'#fff')
        draw = ImageDraw.Draw(sheet)
        draw.text((12,10),f'Helicopter Setup - {width} x {height} code previews (desktop fonts)',font=font(18),fill='#26394c')
        for i,s in enumerate(selected):
            picture = render(s)
            if scale != 1:
                picture=picture.resize((tile_w,tile_h),Image.Resampling.LANCZOS)
            x,y=10+(i%3)*(tile_w+10),46+(i//3)*(tile_h+32)
            sheet.paste(picture,(x,y))
            draw.text((x,y+tile_h+3),f'{s["step"]:02d} {s["name"]}',font=font(14),fill='#26394c')
        sheet.save(args.output/f'overview-{label}.png')
        # Native-size detail sheet: the drawing must be assessable without zooming
        # out to all 19 steps. All four panels come from the actual Lua scene.
        focus = [s for s in scenes if s['width']==width and s['height']==height and
                 ((s['step']==6 and s.get('task')=='120') or
                  (s['step']==13 and s.get('task')==2) or
                  (s['step'] in (15,16) and 'task' not in s))]
        focus.sort(key=lambda s:s['step'])
        detail = Image.new('RGB',(width*2+30,(height+28)*2+48),'#fff')
        draw = ImageDraw.Draw(detail)
        draw.text((10,10),f'{width} x {height} - illustrated tasks (example values)',font=font(16),fill='#26394c')
        for i,s in enumerate(focus):
            x,y=10+(i%2)*(width+10),42+(i//2)*(height+28)
            detail.paste(render(s),(x,y))
        detail.save(args.output/f'illustrations-{label}.png')
        motions = sorted({s['motion'] for s in scenes if s['width']==width and s['height']==height and 'motion' in s})
        for group in motions:
            frames=[]
            samples=sorted((s for s in scenes if s['width']==width and s['height']==height and s.get('motion')==group), key=lambda s:s['frame'])
            for sample in samples:
                frame=Image.new('RGB',(width,height+26),'white')
                frame.paste(render(sample),(0,26))
                ImageDraw.Draw(frame).text((6,5),f"Binding example: {group} = {sample['input']}",font=font(13),fill='#26394c')
                frames.append(frame)
            frames[0].save(args.output/f'motion-{group}-{label}.gif',save_all=True,append_images=frames[1:],duration=1000,loop=0)
            animations += 1
    print(f'Rendered {pictures} individual images, three overview sheets, three illustration sheets and {animations} binding animations.')


if __name__=='__main__':
    main()
