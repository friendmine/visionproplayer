#!/usr/bin/env python3
"""Create a 30-second pan/cut stress fixture from the existing licensed BBB clip.

Five six-second extracts, reordered with matched audio, plus an aspect-preserving
moving crop. Does not download content or change the existing test fixtures.
Big Buck Bunny (c) Blender Foundation, CC BY 3.0; source attribution in VALIDATION.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
folder = root / '.build/TestMedia'
source = folder / 'BBB-HEVC-2D-30s.mp4'
if not source.exists():
    raise SystemExit('Prepare the existing BBB compatibility sample first.')
mp4 = folder / 'BBB-Motion-2D-30s.mp4'
filters = ['[0:v]split=5[v0][v1][v2][v3][v4]', '[0:a]asplit=5[a0][a1][a2][a3][a4]']
for i, start in enumerate([0, 18, 6, 24, 12]):
    filters.append(f'[v{i}]trim=start={start}:duration=6,setpts=PTS-STARTPTS,'
                   "crop=w=1536:h=864:x='(in_w-out_w)*(0.5+0.48*sin(t*3))':y=(in_h-out_h)/2,"
                   f'scale=1920:1080,setsar=1[ov{i}]')
    filters.append(f'[a{i}]atrim=start={start}:duration=6,asetpts=PTS-STARTPTS[oa{i}]')
filters.append(''.join(f'[ov{i}][oa{i}]' for i in range(5)) + 'concat=n=5:v=1:a=1[v][a]')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(source),
                '-filter_complex',';'.join(filters),'-map','[v]','-map','[a]',
                '-c:v','libx264','-preset','fast','-crf','20','-pix_fmt','yuv420p',
                '-c:a','aac','-b:a','128k','-movflags','+faststart',str(mp4)],check=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(mp4),
                '-map','0','-c','copy',str(mp4.with_suffix('.mkv'))],check=True)
print(mp4)
print(mp4.with_suffix('.mkv'))
