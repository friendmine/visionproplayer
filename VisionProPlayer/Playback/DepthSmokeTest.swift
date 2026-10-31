import Foundation

extension PlayerModel {
    #if DEBUG
    func runDepthProbe(name: String) async {
        let engine: PlaybackEngine = name == "depth-vlc" ? .vlc : .native
        let sample: CompatibilitySample = engine == .vlc ? .hevcMKV : .hevcMP4
        var checks: [[String: Any]] = []
        func waitUntil(seconds: Double = 10, _ predicate: () -> Bool) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        depthPopOut = 0.6
        depthStrength = 0.35
        openSample(sample.url, layout: .flat, engine: engine, convert2D: true)
        await waitForPendingChange()
        await waitUntil(seconds: 45) { depthPredictions > 8 || rendererError != nil || errorMessage != nil }
        checks.append(["name": "model-and-render-started", "passed": depthPredictions > 8 && rendererError == nil && errorMessage == nil])
        seek(to: 0.1)
        let warmCount = depthPredictions
        await waitUntil { depthPredictions > warmCount + 8 || rendererError != nil }
        let start = ProcessInfo.processInfo.systemUptime, startFrames = renderedFrames, startInferences = depthPredictions
        let startMedia = elapsed
        let convertedStart = depthConvertedFrames
        depthInferenceSamples.removeAll(); depthAgeSamples.removeAll()
        try? await Task.sleep(for: .seconds(10))
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let fps = Double(renderedFrames - startFrames) / seconds
        let times = depthInferenceSamples.sorted(), ages = depthAgeSamples.sorted()
        let mean = times.reduce(0, +) / Double(max(1, times.count))
        let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        let age95 = ages.isEmpty ? 0 : ages[min(ages.count - 1, Int(Double(ages.count) * 0.95))]
        checks.append(["name": "sustained-conversion", "passed": fps >= 24 && fps <= 36 && depthConvertedFrames > convertedStart + 200 && depthPredictions > startInferences + 100
            && elapsed > startMedia + 8 && rendererError == nil && errorMessage == nil && abs(stereoDisplayAspect - 16.0 / 9.0) < 0.01])
        let convertedDuringBenchmark = depthConvertedFrames - convertedStart
        let revision = depthRevision
        seek(to: 0.5)
        try? await Task.sleep(for: .seconds(1))
        checks.append(["name": "seek-resets-depth-history", "passed": depthRevision > revision && elapsed > 14 && elapsed < 18])
        if isPlaying { togglePlayback() }
        try? await Task.sleep(for: .milliseconds(500))
        let paused = elapsed
        try? await Task.sleep(for: .milliseconds(700))
        let held = !isPlaying && abs(elapsed - paused) < 0.2
        let oldFrames = renderedFrames
        depthStrength = 0
        await waitUntil(seconds: 2) { renderedFrames > oldFrames }
        let zeroRedrew = renderedFrames > oldFrames
        let zeroFrames = renderedFrames
        depthStrength = 0.7
        await waitUntil(seconds: 2) { renderedFrames > zeroFrames }
        checks.append(["name": "pause-and-strength-redraw", "passed": held && zeroRedrew && renderedFrames > zeroFrames && !isPlaying])
        let beforePop = renderedFrames
        depthPopOut = 1
        await waitUntil(seconds: 2) { renderedFrames > beforePop }
        checks.append(["name": "paused-pop-out-redraw", "passed": renderedFrames > beforePop && !isPlaying && abs(elapsed - paused) < 0.2])
        depthPopOut = 0.6
        depthStrength = 0.35
        let beforeResume = depthPredictions
        if !isPlaying { togglePlayback() }
        await waitUntil(seconds: 3) { depthPredictions > beforeResume + 5 }
        checks.append(["name": "resume-conversion", "passed": isPlaying && elapsed > paused && depthPredictions > beforeResume])

        let beforeOff = elapsed
        setDepthConversion(false)
        await waitForPendingChange()
        await waitUntil { elapsed >= beforeOff - 0.5 && isPlaying }
        checks.append(["name": "disable-preserves-position", "passed": request?.converts2D == false && elapsed >= beforeOff - 0.5 && isPlaying])
        setDepthConversion(true)
        await waitForPendingChange()
        await waitUntil { depthPredictions > 5 }
        checks.append(["name": "reenable-conversion", "passed": request?.converts2D == true && depthPredictions > 5 && rendererError == nil])
        let report = smokeMetadata().merging([
            "sample": name, "engine": engine.rawValue, "checks": checks, "popOut": depthPopOut, "screenWidthMeters": depthScreenWidthMeters,
            "benchmarkSeconds": seconds, "submittedFPS": fps, "inferenceMeanMS": mean,
            "inferenceP95MS": p95, "depthAgeP95MS": age95, "convertedFramesInBenchmark": convertedDuringBenchmark,
            "frameSize": frameSize, "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "error": errorMessage ?? rendererError ?? "", "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "10-second warmed-up submission benchmark, not headset scanout FPS or long-run thermal validation. Perceived depth, artifacts and audio sync need manual observation."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-\(name).json"), options: .atomic)
        }
    }
    #endif
}
