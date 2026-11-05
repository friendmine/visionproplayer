#!/usr/bin/env python3
"""Summarize bounded physical-device VLC output traces (not headset scanout)."""
import argparse
import json
from pathlib import Path


def timing(values):
    ordered = sorted(values)
    return {"samples": len(ordered), "p95MS": ordered[min(len(ordered)-1, int(len(ordered)*.95))] if ordered else None,
            "maximumMS": max(ordered, default=None), "over50MS": sum(x > 50 for x in ordered)}


def summarize(path):
    report = json.loads(path.read_text())
    events = report.get("vlcFrameTrace", [])
    stages = {}
    for event, name in enumerate(("convertedOutputReady", "presentation", "snapshot", "consumed")):
        times = sorted(time for time, kind in events if kind == event)
        stages[name] = timing([(b-a)*1000 for a, b in zip(times, times[1:])])
    ready = presentation = None
    waits, copies = [], []
    for time, event in sorted(events):
        if event == 0:
            ready = time
        elif event == 1:
            presentation = time
            if ready is not None:
                waits.append((time-ready)*1000)
                ready = None
        elif event == 2 and presentation is not None:
            copies.append((time-presentation)*1000)
            presentation = None
    times = report.get("submissionTimes", [])
    stages["appSubmission"] = timing([(b-a)*1000 for a, b in zip(times, times[1:])])
    return {"report": path.name, "runID": report["runID"], "passed": report["passed"],
            "submittedFPS": report.get("submittedFPS"), "stages": stages,
            "readyToPresentation": timing(waits), "snapshotCopy": timing(copies),
            "gpuP95MS": report.get("gpuP95MS"), "inferenceP95MS": report.get("inferenceP95MS"),
            "scope": "10-second warmed short sample; converted output readiness is after decode/scaling. No scanout, long-run or perceived AV-sync claim."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.reports], indent=2))
