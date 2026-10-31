#!/usr/bin/env python3
"""Run one Debug probe on a paired physical Vision Pro; the app must be installed."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="CoreDevice identifier or UDID")
    parser.add_argument("sample", choices=["2d", "mkv", "sbs-native", "sbs-vlc", "bbb-native", "bbb-vlc", "lifecycle"])
    args = parser.parse_args()
    bundle = "com.jeff.visionproplayer"
    output = Path(__file__).resolve().parent.parent / ".build/physical-validation"
    output.mkdir(parents=True, exist_ok=True)

    def run(*arguments):
        return subprocess.run(["xcrun", "devicectl", *arguments], capture_output=True, text=True, timeout=25)

    with tempfile.TemporaryDirectory(prefix="vpp-device-") as temporary:
        inventory = Path(temporary) / "devices.json"
        result = run("list", "devices", "--json-output", str(inventory), "--timeout", "20")
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        devices = json.loads(inventory.read_text())["result"]["devices"]
        selected = None
        for device in devices:
            properties = device.get("properties", {})
            hardware = properties.get("hardware", device.get("hardwareProperties", {}))
            if args.device in (device.get("identifier"), hardware.get("udid")):
                if hardware.get("platform") != "visionOS" or hardware.get("reality") != "physical":
                    raise SystemExit("Refusing to run physical-device validation on a simulator or another platform.")
                selected = device["identifier"]
                break
        if selected is None:
            raise SystemExit("Physical Vision Pro not found. Check pairing and unlock the headset.")

        run_id = str(uuid.uuid4())
        result = run("device", "process", "launch", "--device", selected,
                     "--terminate-existing", "--timeout", "20", bundle,
                     "--smoke", args.sample, "--smoke-run-id", run_id)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        print(f"Started {args.sample} on physical Vision Pro (run {run_id})", flush=True)
        deadline = time.monotonic() + 55
        local = Path(temporary) / "report.json"
        while time.monotonic() < deadline:
            time.sleep(2)
            result = run("device", "copy", "from", "--device", selected,
                         "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                         "--source", f"Documents/smoke-{args.sample}.json",
                         "--destination", str(local), "--timeout", "10")
            if result.returncode or not local.exists():
                continue
            report = json.loads(local.read_text())
            if report.get("runID") != run_id:
                continue
            if report.get("environment") != "physical-device":
                raise SystemExit("Report does not identify a physical device.")
            destination = output / f"{args.sample}.json"
            destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(destination)
            print(json.dumps(report, ensure_ascii=False, indent=2))
            raise SystemExit(0 if report.get("passed") else 1)
        raise SystemExit("No current report received within 55 seconds. Keep the headset awake and the app visible.\n"
                         + result.stdout + result.stderr)


if __name__ == "__main__":
    main()
