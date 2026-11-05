#!/usr/bin/env python3
"""Create a small six-second calibration clip for timestamp and eye-crop checks."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / ".build/TestMedia"
output.mkdir(parents=True, exist_ok=True)
filters = []
for start, colors in [(0, ["red", "lime", "blue", "white"]), (3, ["blue", "white", "red", "lime"])]:
    for (x, y), color in zip([(0, 0), (160, 0), (0, 120), (160, 120)], colors):
        filters.append(f"drawbox=x={x}:y={y}:w=160:h=120:color={color}:t=fill:enable='gte(t,{start})'")
filters.append("scale=in_color_matrix=bt601:out_color_matrix=bt709")
subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x240:r=10:d=6",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-vf", ",".join(filters),
                "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10", "-c:a", "aac", "-shortest",
                str(output / "SeekPreview.mp4")], check=True)
subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(output / "SeekPreview.mp4"), "-c", "copy",
                str(output / "SeekPreview.mkv")], check=True)
