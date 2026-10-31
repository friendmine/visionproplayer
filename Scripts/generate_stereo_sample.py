#!/usr/bin/env python3
"""Render an original stereo depth scene; requires Pillow and ffmpeg, generation only."""
import math
import subprocess
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[1] / "VisionProPlayer/Resources"
WIDTH, HEIGHT, SCALE = 640, 360, 2
FOCAL, BASELINE, SCREEN_DISTANCE = 500.0, 0.06, 3.0
FONT = ImageFont.load_default(size=20 * SCALE)
SMALL = ImageFont.load_default(size=11 * SCALE)


def project(x, y, z, eye):
    # Parallel cameras with off-axis projection: z=3 has zero disparity.
    return ((WIDTH / 2 + FOCAL * (x - eye) / z + FOCAL * eye / SCREEN_DISTANCE) * SCALE,
            (HEIGHT / 2 - FOCAL * y / z) * SCALE)


@lru_cache(maxsize=128)
def sphere(radius, color):
    size = radius * 2 + 2
    sprite = Image.new("RGBA", (size, size))
    pixels = sprite.load()
    for y in range(size):
        ny = (y - radius) / radius
        for x in range(size):
            nx = (x - radius) / radius
            squared = nx * nx + ny * ny
            if squared <= 1:
                nz = math.sqrt(1 - squared)
                diffuse = max(0, -0.4 * nx - 0.5 * ny + 0.76 * nz)
                highlight = max(0, -0.28 * nx - 0.35 * ny + 0.89 * nz) ** 45
                pixels[x, y] = tuple(min(255, int(c * (0.22 + 0.78 * diffuse) + 120 * highlight))
                                     for c in color) + (255,)
    return sprite


def frame(time, eye):
    canvas = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), (9, 17, 32))
    draw = ImageDraw.Draw(canvas)
    for x in range(-6, 7):
        draw.line([project(x * .4, -.72, z, eye) for z in [1.6, 8]],
                  fill=(25, 55, 74), width=SCALE)
    for z in [2, 2.5, 3, 4, 5, 6, 8]:
        draw.line([project(x, -.72, z, eye) for x in [-2.4, 2.4]],
                  fill=(25, 55, 74), width=SCALE)
    for z in [7, 5.5, 4.2]:
        points = [project(.85 * math.cos(i * math.tau / 96),
                          .85 * math.sin(i * math.tau / 96), z, eye) for i in range(97)]
        draw.line(points, fill=(29, 83, 103), width=2 * SCALE)

    objects = [(0.9, .3, 5.8, .30, (211, 115, 239), "FAR"),
               (-.42, .15, 3.0, .24, (77, 205, 234), "MIDDLE"),
               (.15 + .18 * math.sin(math.tau * time / 12), -.10,
                1.85 + .15 * math.sin(math.tau * time / 12), .19, (255, 186, 65), "NEAR")]
    for x, y, z, radius, color, label in objects:
        cx, cy = project(x, y, z, eye)
        pixel_radius = round(FOCAL * radius / z * SCALE)
        sprite = sphere(pixel_radius, color)
        canvas.paste(sprite, (round(cx - pixel_radius), round(cy - pixel_radius)), sprite)
        draw.text((cx, cy + pixel_radius + 9 * SCALE), label, font=SMALL,
                  fill=color, anchor="mt")

    # Identical zero-disparity captions avoid the old LEFT/RIGHT label rivalry.
    draw.text((24 * SCALE, 19 * SCALE), "STEREO DEPTH DEMO", font=FONT, fill=(222, 236, 246))
    draw.text((24 * SCALE, 46 * SCALE), "Gold: near    Cyan: middle    Violet: far", font=SMALL,
              fill=(139, 167, 189))
    draw.text((24 * SCALE, 331 * SCALE), "Same scene. Two eye positions. Three depth layers.",
              font=SMALL, fill=(139, 167, 189))
    return canvas.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)


def main():
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "1280x360",
               "-framerate", "30", "-i", "pipe:0", "-f", "lavfi", "-i",
               "sine=frequency=660:sample_rate=48000:duration=12",
               "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "fast",
               "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
               "-t", "12", "-movflags", "+faststart", str(OUT / "SampleSBS.mp4")]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    try:
        for index in range(360):
            packed = Image.new("RGB", (WIDTH * 2, HEIGHT))
            packed.paste(frame(index / 30, -BASELINE / 2), (0, 0))
            packed.paste(frame(index / 30, BASELINE / 2), (WIDTH, 0))
            process.stdin.write(packed.tobytes())
    finally:
        process.stdin.close()
    if process.wait():
        raise SystemExit("Stereo sample encoding failed")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i",
                    str(OUT / "SampleSBS.mp4"), "-c", "copy", str(OUT / "SampleSBS.mkv")], check=True)
    print("Generated 12-second full SBS depth scene (MP4 and MKV).")


if __name__ == "__main__":
    main()
