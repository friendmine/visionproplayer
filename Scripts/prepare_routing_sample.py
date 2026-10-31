#!/usr/bin/env python3
"""Create a synthetic AVI and a deliberately mislabeled copy for fallback checks."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / ".build/TestMedia"
output.mkdir(parents=True, exist_ok=True)
avi = output / "FallbackProbe.avi"
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-i", str(root / "VisionProPlayer/Resources/Sample2D.mp4"),
    "-c:v", "mpeg4", "-q:v", "5", "-vtag", "DX50", "-c:a", "libmp3lame", str(avi)
], check=True)
# Same bytes, different extension: automatic routing first tries AVPlayer,
# which rejects this AVI/DivX fixture on the tested visionOS device.
shutil.copyfile(avi, avi.with_suffix(".mp4"))
print(f"Created routing fixtures in {output}")
