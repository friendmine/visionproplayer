#!/usr/bin/env python3
"""Self-authored stereo reference. No model, private media, or depth inference."""
from pathlib import Path
import shutil
import subprocess
from PIL import Image, ImageDraw, ImageFont

out = Path(__file__).resolve().parent.parent / '.build/TestMedia'
out.mkdir(parents=True, exist_ok=True)
width, height = 1024, 576
image = Image.new('RGB', (width * 2, height), '#101823')
font_path = '/System/Library/Fonts/Supplemental/Arial.ttf'
font = ImageFont.truetype(font_path, 28)
small = ImageFont.truetype(font_path, 22)
for eye in range(2):
    x = eye * width
    draw = ImageDraw.Draw(image)
    for line in range(64, width, 64):
        draw.line((x+line, 90, x+line, height-60), fill='#344353', width=1)
    for line in range(112, height-60, 48):
        draw.line((x+35, line, x+width-35, line), fill='#344353', width=1)
    draw.rectangle((x+30, 85, x+width-30, height-50), outline='white', width=4)
    draw.text((x+40, 28), 'LEFT EYE' if eye == 0 else 'RIGHT EYE', font=font,
              fill='#ff7777' if eye == 0 else '#77bbff')
    direction = 1 if eye == 0 else -1
    for center, shift, color, label in [(260, 32*direction, '#ffd35a', 'IN FRONT'),
                                       (512, 0, '#eeeeee', 'ON SCREEN'),
                                       (764, -16*direction, '#3bd8ef', 'BEHIND')]:
        cx, cy = x+center+shift, 275
        draw.ellipse((cx-66, cy-66, cx+66, cy+66), fill=color, outline='#ffffff', width=2)
        draw.line((cx-24, cy, cx+24, cy), fill='#15212d', width=4)
        draw.line((cx, cy-24, cx, cy+24), fill='#15212d', width=4)
        draw.text((cx, 370), label, font=small, anchor='mm', fill=color)
    draw.text((x+width/2, height-25), 'WHITE FRAME = SCREEN PLANE / FULL SBS / NO AI', font=small, anchor='mm', fill='white')
image.save(out/'StereoReference.png')
subprocess.run([shutil.which('ffmpeg') or 'ffmpeg', '-y', '-v', 'error', '-loop', '1',
                '-i', str(out/'StereoReference.png'), '-t', '60', '-r', '30',
                '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '18', '-pix_fmt', 'yuv420p',
                '-movflags', '+faststart', str(out/'StereoReference.mp4')], check=True)
print(out/'StereoReference.mp4')
