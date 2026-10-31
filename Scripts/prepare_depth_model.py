#!/usr/bin/env python3
"""Download the pinned Apple Core ML conversion of Depth Anything V2 Small."""
import hashlib
from pathlib import Path
import subprocess
import urllib.request
import zipfile

root = Path(__file__).resolve().parent.parent
destination = root / '.build/Models'
destination.mkdir(parents=True, exist_ok=True)
archive = destination / 'DepthAnythingV2SmallF16.zip'
url = 'https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16.mlpackage.zip'
expected = '8e875979ec82fa46f292468a7567a520b2aa07c41008c32141f3396da05a4067'
if not archive.exists():
    temporary = archive.with_suffix('.download')
    urllib.request.urlretrieve(url, temporary)
    temporary.replace(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('Model checksum mismatch; no model was extracted.')
with zipfile.ZipFile(archive) as package:
    for info in package.infolist():
        if info.filename.startswith('DepthAnythingV2SmallF16.mlpackage/'):
            target = (destination / info.filename).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise SystemExit('Unsafe model archive path')
            package.extract(info, destination)
subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(destination / 'DepthAnythingV2SmallF16.mlpackage'),
                str(destination)], check=True)
print('Verified and compiled Depth Anything V2 Small F16. Weights remain outside Git.')
