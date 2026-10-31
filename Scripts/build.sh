#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project VisionProPlayer.xcodeproj -scheme VisionProPlayer \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build "$@"
