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
    if "--proportions" in arguments:
        arguments.remove("--proportions")
        fixture = "test_proportion_protection.swift"
    shutil.copyfile(root / "Scripts" / fixture, main)
    executable = folder / "test-depth-warp"
    subprocess.run(["swiftc", "-O", str(root / "VisionProPlayer/Rendering/StereoReprojector.swift"),
                    str(main), "-o", str(executable)], cwd=root, check=True)
    subprocess.run([str(executable), *arguments], cwd=root, check=True)
