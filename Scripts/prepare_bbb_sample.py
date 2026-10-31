#!/usr/bin/env python3
"""Make a 60-second Full SBS test excerpt from Blender's 1080p30 stereo ABL release."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path(".build/TestMedia"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(args.source)]))
    video = next(s for s in metadata["streams"] if s["codec_type"] == "video")
    if (video["width"], video["height"]) != (1920, 2160):
        raise SystemExit("Expected the full-height 1920x2160 above/below stereo source.")
    mp4 = args.output / "BBB-SBS-60s.mp4"
    mkv = args.output / "BBB-SBS-60s.mkv"
    credit = "(c) 2008 Blender Foundation / www.bigbuckbunny.org; CC BY 3.0; Sunflower stereo by Janus Kristensen (2013). Excerpt 00:20-01:20, resized and repacked to Full SBS."
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror", "-y", "-ss", "20",
        "-i", str(args.source), "-t", "60", "-map", "0:v:0", "-map", "0:a:0",
        "-vf", "stereo3d=abl:sbsl,scale=1920:540,setsar=1",
        "-c:v", "libx264", "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-ac", "2", "-b:a", "160k", "-movflags", "+faststart",
        "-metadata", f"comment={credit}", str(mp4)], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(mp4), "-c", "copy", str(mkv)], check=True)
    outputs = {}
    for path in [mp4, mkv]:
        info = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
        v = next(s for s in info["streams"] if s["codec_type"] == "video")
        a = next(s for s in info["streams"] if s["codec_type"] == "audio")
        assert (v["width"], v["height"], v["codec_name"], a["codec_name"]) == (1920, 540, "h264", "aac")
        assert abs(float(info["format"]["duration"]) - 60) < .2
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
                        "-i", str(path), "-f", "null", "-"], check=True)
        outputs[path.name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                              "bytes": path.stat().st_size, "fullDecode": "passed"}
    report = {"source": "https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_stereo_abl.mp4.zip",
              "license": "https://creativecommons.org/licenses/by/3.0/",
              "licenseEvidence": "https://peach.blender.org/about/", "attribution": credit,
              "sourceIntervalSeconds": [20, 80], "layout": "Full SBS, left eye first",
              "perEyeSize": [960, 540], "fps": 30, "outputs": outputs}
    (args.output / "BBB-SBS-60s.json").write_text(json.dumps(report, indent=2) + "\n")
    (args.output / "BBB-SBS-60s-LICENSE.txt").write_text(credit + "\n" + report["license"] + "\n" + report["source"] + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
