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
    parser.add_argument("--capture", action="store_true", help="Save the first converted eye textures in the app Documents directory (Debug only)")
    parser.add_argument("--baseline", action="store_true", help="Use the preserved 0.6.2 depth path for an AI comparison")
    parser.add_argument("--resume-stress", action="store_true", help="Repeat paused-seek/resume checks with clock traces")
    parser.add_argument("sample", choices=["ou-native", "ou-vlc", "half-ou-native", "half-ou-vlc", "2d", "mkv", "sbs-native", "sbs-vlc", "bbb-native", "bbb-vlc", "lifecycle", "routing", "product", "depth-native", "depth-vlc", "depth-motion-native", "depth-motion-vlc", "depth-endurance-native", "depth-endurance-vlc",
                                           "hevc-mp4", "hevc-mkv", "half-h264-native", "half-h264-vlc", "half-hevc-native", "half-hevc-vlc"])
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
                     "--smoke", args.sample, "--smoke-run-id", run_id, *(["--depth-capture"] if args.capture else []),
                     *(["--depth-motion-baseline"] if args.baseline else []),
                     *(["--depth-resume-stress"] if args.resume_stress else []))
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        print(f"Started {args.sample} on physical Vision Pro (run {run_id})", flush=True)
        endurance = args.sample.startswith("depth-endurance-")
        report_timeout = 1380 if endurance else 180 if args.resume_stress else 150 if args.sample == "product" else 120 if args.sample.startswith("depth-") else (95 if args.sample == "routing" else 55)
        deadline = time.monotonic() + report_timeout
        local = Path(temporary) / "report.json"
        progress_file = Path(temporary) / "progress.json"
        completed_segments = 0
        while time.monotonic() < deadline:
            time.sleep(10 if endurance else 2)
            if endurance:
                progress_result = run("device", "copy", "from", "--device", selected,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                    "--source", f"Documents/smoke-{args.sample}-progress.json",
                    "--destination", str(progress_file), "--timeout", "10")
                if progress_result.returncode == 0 and progress_file.exists():
                    progress_report = json.loads(progress_file.read_text())
                    if progress_report.get("runID") == run_id and progress_report.get("completedSegments", 0) > completed_segments:
                        completed_segments = progress_report["completedSegments"]
                        print(json.dumps(progress_report, ensure_ascii=False), flush=True)
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
            destination = output / f"{args.sample}{'-baseline' if args.baseline else ''}{'-resume-stress' if args.resume_stress else ''}.json"
            destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            print(destination)
            print(json.dumps(report, ensure_ascii=False, indent=2))
            raise SystemExit(0 if report.get("passed") else 1)
        raise SystemExit(f"No current report received within {report_timeout} seconds. Keep the headset awake and the app visible.\n"
                         + result.stdout + result.stderr)


if __name__ == "__main__":
    main()
