#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d .build/Models/DepthAnythingV2SmallF16.mlmodelc ]]; then
  echo 'Prepare the pinned depth model first: python3 Scripts/prepare_depth_model.py' >&2
  exit 1
fi
xcodebuild -project VisionProPlayer.xcodeproj -scheme VisionProPlayer \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build "$@"
