#!/usr/bin/env python3
"""Prepare OU probes from the user's Blender stereo ABL source (not bundled)."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
out = Path(__file__).resolve().parent.parent / '.build/TestMedia'
out.mkdir(parents=True, exist_ok=True)
full, half = out / 'BBB-Full-OU.mp4', out / 'BBB-Half-OU.mp4'
# Copy keeps the original H.264 + MP3 streams, including the preceding keyframe.
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-ss', '20', '-i', str(args.source), '-t', '30', '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', '-avoid_negative_ts', 'make_zero', '-y', str(full)], check=True)
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(full), '-vf', 'scale=1920:1080,setsar=1', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22', '-c:a', 'aac', '-b:a', '128k', '-y', str(half)], check=True)
records = []
for path in [full, half]:
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'stream=codec_name,width,height:format=duration', '-of', 'json', str(path)]))
    records.append({'name': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'probe': probe})
(out / 'ou-samples.json').write_text(json.dumps(records, indent=2) + '\n')
print(out)
