#!/usr/bin/env python3
"""Measure horizontal correspondences in captured eye images (not perceived depth).

Requires OpenCV and NumPy. Positive x_left - x_right is crossed disparity.
Reject ambiguous patches and matches that fail a right-to-left check.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def analyze(left, right):
    if left is None or right is None or left.shape != right.shape:
        raise ValueError("Both eye images must exist and have equal dimensions")
    height, width = left.shape
    radius, reach = 10, int(np.ceil(width * 0.08))
    points = cv2.goodFeaturesToTrack(left, 600, 0.02, 24, blockSize=9)

    def match(source, target, x, y):
        lo, hi = max(radius, x - reach), min(width - radius - 1, x + reach)
        patch = source[y-radius:y+radius+1, x-radius:x+radius+1]
        strip = target[y-radius:y+radius+1, lo-radius:hi+radius+1]
        scores = cv2.matchTemplate(strip, patch, cv2.TM_CCOEFF_NORMED)[0]
        best = int(np.argmax(scores))
        score = float(scores[best])
        others = scores.copy()
        others[max(0, best-3):best+4] = -1
        if score < 0.93 or score - float(others.max()) < 0.03:
            return None
        return lo + best

    samples = []
    for point in ([] if points is None else points):
        x, y = np.rint(point[0]).astype(int)
        if not (radius <= x < width-radius and radius <= y < height-radius):
            continue
        rx = match(left, right, x, y)
        if rx is None:
            continue
        lx = match(right, left, rx, y)
        if lx is not None and abs(lx - x) <= 1:
            samples.append(int(x - rx))
    if len(samples) < 10:
        raise ValueError("Too few unambiguous correspondences; inspect manually")
    percentiles = np.percentile(samples, [5, 50, 95])
    return {
        "width": width, "height": height, "matchedFeatures": len(samples),
        "disparityPixelsP05P50P95": percentiles.tolist(),
        "disparityWidthPercentP05P50P95": (percentiles / width * 100).tolist(),
        "positiveFraction": float(np.mean(np.array(samples) > 0)),
        "scope": "Texture patch correspondences only; not headset scanout, physical depth, or perceptual acceptance.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(cv2.imread(str(args.left), 0), cv2.imread(str(args.right), 0)), indent=2))
