import Foundation

extension PlayerModel {
    #if DEBUG
    func runDepthProbe(name: String) async {
        let engine: PlaybackEngine = name.hasSuffix("vlc") ? .vlc : .native
        let sample: CompatibilitySample = engine == .vlc ? .hevcMKV : .hevcMP4
        let source = name.hasPrefix("depth-motion-")
            ? URL.documentsDirectory.appending(path: engine == .vlc ? "BBB-Motion-2D-30s.mkv" : "BBB-Motion-2D-30s.mp4") : sample.url
        var checks: [[String: Any]] = []
        func waitUntil(seconds: Double = 10, _ predicate: () -> Bool) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        depthPopOut = 0.6
        depthStrength = 0.35
        depthProportionProtection = true
        openSample(source, layout: .flat, engine: engine, convert2D: true)
        await waitForPendingChange()
        await waitUntil(seconds: 45) { depthPredictions > 8 || rendererError != nil || errorMessage != nil }
        checks.append(["name": "model-and-render-started", "passed": depthPredictions > 8 && rendererError == nil && errorMessage == nil])
        seek(to: 0.1)
        let warmCount = depthPredictions
        await waitUntil { depthPredictions > warmCount + 8 || rendererError != nil }
        let start = ProcessInfo.processInfo.systemUptime, startFrames = renderedFrames, startInferences = depthPredictions
        let startMedia = elapsed
        let startClock = vlc?.clockDiagnostics ?? [:]
        let convertedStart = depthConvertedFrames
        let resetStart = depthSceneResets
        depthInferenceSamples.removeAll(); depthAgeSamples.removeAll(); depthGainSamples.removeAll()
        try? await Task.sleep(for: .seconds(10))
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let fps = Double(renderedFrames - startFrames) / seconds
        let times = depthInferenceSamples.sorted(), ages = depthAgeSamples.sorted()
        let gains = depthGainSamples.sorted()
        let sceneResets = depthSceneResets - resetStart
        let mean = times.reduce(0, +) / Double(max(1, times.count))
        let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        let age95 = ages.isEmpty ? 0 : ages[min(ages.count - 1, Int(Double(ages.count) * 0.95))]
        checks.append(["name": "sustained-conversion", "passed": fps >= 24 && fps <= 36 && depthConvertedFrames > convertedStart + 200 && depthPredictions > startInferences + 100
            && elapsed > startMedia + 8 && rendererError == nil && errorMessage == nil && abs(stereoDisplayAspect - 16.0 / 9.0) < 0.01, "startMedia": startMedia, "endMedia": elapsed, "startClock": startClock, "endClock": vlc?.clockDiagnostics ?? [:]])
        let convertedDuringBenchmark = depthConvertedFrames - convertedStart
        // Exercise larger disocclusions separately from the default benchmark.
        depthStrength = 0.6; depthPopOut = 1
        seek(to: 0.1)
        let highWarm = depthPredictions
        await waitUntil { depthPredictions > highWarm + 8 || rendererError != nil }
        let highStart = ProcessInfo.processInfo.systemUptime, highFrames = renderedFrames
        let highConverted = depthConvertedFrames, highMedia = elapsed
        try? await Task.sleep(for: .seconds(8))
        let highSeconds = ProcessInfo.processInfo.systemUptime - highStart
        let highFPS = Double(renderedFrames - highFrames) / highSeconds
        let highConvertedCount = depthConvertedFrames - highConverted
        checks.append(["name": "high-relief-sustained-conversion", "passed": highFPS >= 24 && highFPS <= 36
            && highConvertedCount > 160 && elapsed > highMedia + 6 && rendererError == nil && errorMessage == nil])
        depthStrength = 0.35; depthPopOut = 0.6
        let revision = depthRevision
        seek(to: 0.5)
        try? await Task.sleep(for: .seconds(1))
        checks.append(["name": "seek-resets-depth-history", "passed": depthRevision > revision && elapsed > 14 && elapsed < 18])
        if isPlaying { togglePlayback() }
        try? await Task.sleep(for: .milliseconds(500))
        var paused = elapsed
        try? await Task.sleep(for: .milliseconds(700))
        let held = !isPlaying && abs(elapsed - paused) < 0.2
        let settledFrames = renderedFrames, settledPredictions = depthPredictions
        try? await Task.sleep(for: .seconds(2))
        let pausedFrameUpdates = renderedFrames - settledFrames
        let pausedDepthUpdates = depthPredictions - settledPredictions
        checks.append(["name": "paused-picture-stays-static", "passed": pausedFrameUpdates == 0 && pausedDepthUpdates == 0
            && !isPlaying && abs(elapsed - paused) < 0.2])
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
        depthStrength = 0.35
        var redraws = true
        for amount: Float in [0, 0.6, 1] {
            let before = renderedFrames
            depthPopOut = amount
            await waitUntil(seconds: 2) { renderedFrames > before }
            redraws = redraws && renderedFrames > before && !isPlaying && abs(elapsed - paused) < 0.2
        }
        checks.append(["name": "paused-relief-sweep-keeps-position", "passed": redraws])
        // Let the preceding pop-out adjustment finish its depth prediction
        // before measuring the protection switch in isolation.
        let beforeProtectionSetup = renderedFrames
        depthPopOut = 0.6
        await waitUntil(seconds: 3) { renderedFrames > beforeProtectionSetup }
        try? await Task.sleep(for: .seconds(1))
        var protectionRedraws = renderedFrames > beforeProtectionSetup && !isPlaying
        var protectionSamples: [[String: Any]] = []
        for enabled in [false, true] {
            let before = renderedFrames, beforeDepth = depthPredictions
            depthProportionProtection = enabled
            await waitUntil(seconds: 3) { renderedFrames > before }
            protectionRedraws = protectionRedraws && renderedFrames > before && !isPlaying && abs(elapsed - paused) < 0.2
            try? await Task.sleep(for: .milliseconds(400))
            let stableFrames = renderedFrames, stableDepth = depthPredictions
            try? await Task.sleep(for: .milliseconds(500))
            protectionRedraws = protectionRedraws && renderedFrames == stableFrames && depthPredictions == stableDepth && depthPredictions == beforeDepth
            protectionSamples.append(["enabled": enabled, "frameUpdates": renderedFrames - before,
                "depthUpdates": depthPredictions - beforeDepth, "settledFrameUpdates": renderedFrames - stableFrames,
                "settledDepthUpdates": depthPredictions - stableDepth, "playing": isPlaying])
        }
        checks.append(["name": "paused-proportion-protection-toggle-redraws-and-settles", "passed": protectionRedraws,
                       "samples": protectionSamples])
        let beforePausedSeek = renderedFrames
        seek(to: 0.2)
        await waitUntil { renderedFrames > beforePausedSeek && abs(elapsed - 6) < 0.6 }
        let pausedSeekUpdated = renderedFrames > beforePausedSeek && abs(elapsed - 6) < 0.6 && !isPlaying
        try? await Task.sleep(for: .seconds(1))
        paused = elapsed
        let seekSettledFrames = renderedFrames, seekSettledDepth = depthPredictions
        try? await Task.sleep(for: .seconds(1))
        checks.append(["name": "paused-seek-updates-then-settles", "passed": pausedSeekUpdated
            && renderedFrames == seekSettledFrames && depthPredictions == seekSettledDepth && !isPlaying,
            "updated": pausedSeekUpdated, "elapsed": elapsed, "position": progress, "playing": isPlaying,
            "state": stateText, "framesSinceSeek": renderedFrames - beforePausedSeek,
            "settledFrameUpdates": renderedFrames - seekSettledFrames, "settledDepthUpdates": depthPredictions - seekSettledDepth])
        let beforeResume = depthPredictions
        if !isPlaying { togglePlayback() }
        let resumeStart = ProcessInfo.processInfo.systemUptime
        var resumeContinuous = true
        repeat {
            let age = ProcessInfo.processInfo.systemUptime - resumeStart
            resumeContinuous = resumeContinuous && elapsed >= paused - 0.25 && elapsed <= paused + age + 0.75
            try? await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime - resumeStart < 1.5
        checks.append(["name": "resume-conversion", "passed": resumeContinuous && isPlaying && elapsed > paused && elapsed < paused + 3.5 && depthPredictions > beforeResume,
            "continuous": resumeContinuous,
            "elapsed": elapsed, "pausedElapsed": paused, "playing": isPlaying, "newDepthPredictions": depthPredictions - beforeResume, "clock": vlc?.clockDiagnostics ?? [:]])

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
            "sample": name, "engine": engine.rawValue, "depthMapping": "anchored-relief-v2", "projectionSampling": "proportion-protected-forward-v1", "proportionProtection": depthProportionProtection, "checks": checks, "popOut": depthPopOut, "screenWidthMeters": depthScreenWidthMeters,
            "benchmarkSeconds": seconds, "submittedFPS": fps,
            "temporalPolicy": "motion-aware-cuts-continuous-history-v1",
            "sourceFile": source.lastPathComponent, "sceneResetsInBenchmark": sceneResets,
            "depthGainMinimum": gains.first ?? 0,
            "depthGainMedian": gains.isEmpty ? 0 : gains[gains.count / 2],
            "depthGainBelowHalfFrames": gains.filter { $0 < 0.5 }.count,
            "depthGainSamples": gains.count,
            "pausedFrameUpdates": pausedFrameUpdates, "pausedDepthUpdates": pausedDepthUpdates,
            "highReliefSeconds": highSeconds, "highReliefFPS": highFPS, "highReliefConvertedFrames": highConvertedCount, "inferenceMeanMS": mean,
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
