#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Usage: Scripts/smoke_test.sh SIMULATOR_UDID [2d|mkv|sbs-native|sbs-vlc]}"
app='.build/DerivedData/Build/Products/Debug-xrsimulator/VisionProPlayer.app'
bundle='com.jeff.visionproplayer'
mkdir -p .build/validation
xcrun simctl install "$device" "$app"
for sample in ${2:-2d mkv sbs-native sbs-vlc}; do
    xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
    container="$(xcrun simctl get_app_container "$device" "$bundle" data)"
    report="$container/Documents/smoke-$sample.json"
    rm -f "$report"
    xcrun simctl launch "$device" "$bundle" --smoke "$sample"
    for attempt in $(seq 1 35); do
        [ -f "$report" ] && break
        sleep 1
    done
    if [ ! -f "$report" ]; then
        echo "FAIL: $sample did not produce a report" >&2
        exit 1
    fi
    cp "$report" ".build/validation/$sample.json"
    cat "$report"
    xcrun simctl io "$device" screenshot ".build/validation/$sample.png" >/dev/null
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "$report"
done
