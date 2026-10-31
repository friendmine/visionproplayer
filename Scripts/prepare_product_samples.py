#!/usr/bin/env python3
"""Make short multi-track fixtures from the project's original test pattern."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
out = root / '.build/TestMedia'
out.mkdir(parents=True, exist_ok=True)
subtitle = out / 'ProductCaptions.srt'
subtitle.write_text('1\n00:00:00,000 --> 00:00:05,000\nFirst caption / 第一条字幕\n\n2\n00:00:05,000 --> 00:00:11,500\nSecond caption / 第二条字幕\n', encoding='utf-8')
for ext, codec in [('mp4', 'mov_text'), ('mkv', 'srt')]:
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(root/'VisionProPlayer/Resources/Sample2D.mp4'),
                    '-f', 'lavfi', '-i', 'sine=frequency=880:duration=12:sample_rate=48000', '-i', str(subtitle),
                    '-map', '0:v', '-map', '0:a', '-map', '1:a', '-map', '2:0', '-c:v', 'copy', '-c:a', 'aac', '-c:s', codec,
                    '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho', '-metadata:s:s:0', 'language=eng',
                    '-t', '12', str(out/f'ProductTracks.{ext}')], check=True)
print(out)
