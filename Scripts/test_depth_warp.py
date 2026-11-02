#!/usr/bin/env python3
"""Compile and run the GPU checks with the app's actual projection encoder."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="vpp-depth-gpu-") as temporary:
    folder = Path(temporary)
    main = folder / "main.swift"
    arguments = sys.argv[1:]
    fixture = "test_depth_warp.swift"
    support = []
    if "--proportions" in arguments:
        arguments.remove("--proportions")
        fixture = "test_proportion_protection.swift"
    if "--colors" in arguments:
        arguments.remove("--colors")
        fixture = "test_video_color.swift"
    if "--temporal" in arguments:
        arguments.remove("--temporal")
        fixture = "test_depth_temporal.swift"
    if "--scenes" in arguments:
        arguments.remove("--scenes")
        fixture = "test_motion_scenes.swift"
        support = [str(root / "VisionProPlayer/Rendering/DepthEstimator.swift")]
    if "--motion" in arguments:
        arguments.remove("--motion")
        fixture = "test_depth_motion.swift"
        support = [str(root / "VisionProPlayer/Rendering/DepthMotionAligner.swift")]
    if "--edges" in arguments:
        arguments.remove("--edges")
        fixture = "test_depth_edges.swift"
        support = [str(root / "VisionProPlayer/Rendering/DepthEdgeRefiner.swift")]
    shutil.copyfile(root / "Scripts" / fixture, main)
    executable = folder / "test-depth-warp"
    subprocess.run(["swiftc", "-O", str(root / "VisionProPlayer/Rendering/StereoReprojector.swift"),
                    str(root / "VisionProPlayer/Rendering/VideoColorConverter.swift"),
                    str(root / "VisionProPlayer/Rendering/DepthTemporalPolicy.swift"),
                    *support, str(main), "-o", str(executable)], cwd=root, check=True)
    subprocess.run([str(executable), *arguments], cwd=root, check=True)
