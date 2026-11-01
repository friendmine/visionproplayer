#!/usr/bin/env python3
"""Compile and run the GPU checks with the app's actual projection encoder."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="vpp-depth-gpu-") as temporary:
    folder = Path(temporary)
    main = folder / "main.swift"
    shutil.copyfile(root / "Scripts/test_depth_warp.swift", main)
    executable = folder / "test-depth-warp"
    subprocess.run(["swiftc", "-O", str(root / "VisionProPlayer/Rendering/StereoReprojector.swift"),
                    str(main), "-o", str(executable)], cwd=root, check=True)
    subprocess.run([str(executable)], cwd=root, check=True)
