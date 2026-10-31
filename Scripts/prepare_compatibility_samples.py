#!/usr/bin/env python3
"""Generate 1080p SDR HEVC and Half SBS fixtures from the licensed BBB ABL source."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path(".build/TestMedia"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    video = next(s for s in probe(args.source)["streams"] if s["codec_type"] == "video")
    assert (video["width"], video["height"]) == (1920, 2160), "Expected full ABL stereo source"
    credit = "(c) 2008 Blender Foundation / www.bigbuckbunny.org; CC BY 3.0; Sunflower stereo by Janus Bager Kristensen (2013). Excerpt 00:20-00:50; left-eye 2D or Half SBS; transcoded for compatibility testing."
    reports = {}
    for stem, codec, filter_chain in [
        ("BBB-HEVC-2D-30s", "hevc", "crop=1920:1080:0:0,setsar=1"),
        ("BBB-H264-HalfSBS-30s", "h264", "stereo3d=abl:sbsl,scale=1920:1080,setsar=1"),
        ("BBB-HEVC-HalfSBS-30s", "hevc", "stereo3d=abl:sbsl,scale=1920:1080,setsar=1")
    ]:
        mp4 = args.output / f"{stem}.mp4"
        encoder = (["-c:v", "hevc_videotoolbox", "-profile:v", "main", "-b:v", "4M",
                    "-tag:v", "hvc1", "-g", "60", "-allow_sw", "1"] if codec == "hevc" else
                   ["-c:v", "libx264", "-preset", "fast", "-crf", "23", "-g", "60"])
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror", "-y", "-ss", "20",
            "-i", str(args.source), "-t", "30", "-map", "0:v:0", "-map", "0:a:0",
            "-vf", filter_chain, *encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2",
            "-b:a", "160k", "-movflags", "+faststart", "-metadata", f"comment={credit}", str(mp4)], check=True)
        mkv = mp4.with_suffix(".mkv")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(mp4),
                        "-c", "copy", str(mkv)], check=True)
        for path in [mp4, mkv]:
            info = probe(path)
            v = next(s for s in info["streams"] if s["codec_type"] == "video")
            a = next(s for s in info["streams"] if s["codec_type"] == "audio")
            assert (v["codec_name"], v["width"], v["height"], v["pix_fmt"], a["codec_name"]) == (codec, 1920, 1080, "yuv420p", "aac")
            assert v["sample_aspect_ratio"] == "1:1"
            assert abs(float(info["format"]["duration"]) - 30) < .2
            if codec == "hevc":
                assert v["profile"] == "Main"
                if path.suffix == ".mp4": assert v["codec_tag_string"] == "hvc1"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
                            "-i", str(path), "-f", "null", "-"], check=True)
            reports[path.name] = {"codec": codec, "profile": v["profile"], "pixelFormat": v["pix_fmt"],
                "width": v["width"], "height": v["height"], "fps": v["avg_frame_rate"],
                "duration": float(info["format"]["duration"]), "audio": a["codec_name"],
                "layout": "halfSBS" if "HalfSBS" in stem else "flat",
                "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "fullDecode": "passed"}
        print(f"Prepared and decoded {stem}: MP4 + MKV", flush=True)
    manifest = {"source": "https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_stereo_abl.mp4.zip",
                "license": "https://creativecommons.org/licenses/by/3.0/", "attribution": credit,
                "sourceIntervalSeconds": [20, 50], "outputs": reports}
    (args.output / "compatibility-samples.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
