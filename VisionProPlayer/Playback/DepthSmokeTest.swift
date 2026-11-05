import Foundation

extension PlayerModel {
    #if DEBUG
    func runDepthProbe(name: String) async {
        let engine: PlaybackEngine = name.hasSuffix("vlc") ? .vlc : .native
        let sample: CompatibilitySample = engine == .vlc ? .hevcMKV : .hevcMP4
        let source = name.hasPrefix("depth-motion-")
            ? URL.documentsDirectory.appending(path: engine == .vlc ? "BBB-Motion-2D-30s.mkv" : "BBB-Motion-2D-30s.mp4") : sample.url
        var checks: [[String: Any]] = []
        func writeReport(_ report: [String: Any]) { writeDepthProbeReport(report, name: name) }
        let testedAlignment = !ProcessInfo.processInfo.arguments.contains("--depth-motion-baseline")
        let testedEdges = testedAlignment && !ProcessInfo.processInfo.arguments.contains("--depth-reference-063")
        depthMotionAlignment = testedAlignment
        let testedSubjects = testedEdges && !ProcessInfo.processInfo.arguments.contains("--depth-reference-064")
        depthEdgeRefinement = testedEdges
        depthSubjectAccuracy = testedSubjects
        do {
            depthPopOut = 0.6
            depthStrength = 0.35
            depthProportionProtection = true
            openSample(source, layout: .flat, engine: engine, convert2D: true)
            var expectedGeneration = diagnosticPlaybackGeneration
            func validateSource() throws {
                try Task.checkCancellation()
                guard diagnosticPlaybackGeneration == expectedGeneration, showingPlayer else { throw CancellationError() }
            }
            func pause(_ duration: Duration) async throws {
                try validateSource()
                try await Task.sleep(for: duration)
                try validateSource()
            }
            func waitUntil(seconds: Double = 10, _ predicate: () -> Bool) async throws {
                try validateSource()
                let deadline = ProcessInfo.processInfo.systemUptime + seconds
                while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                    try await pause(.milliseconds(100))
                }
            }
            await waitForPendingChange()
            try validateSource()
            try await waitUntil(seconds: 45) { depthPredictions > 8 || rendererError != nil || errorMessage != nil }
            checks.append(["name": "model-and-render-started", "passed": depthPredictions > 8 && rendererError == nil && errorMessage == nil])
            seek(to: 0.1)
            let warmCount = depthPredictions
            try await waitUntil { depthPredictions > warmCount + 8 || rendererError != nil }
            let start = ProcessInfo.processInfo.systemUptime, startFrames = renderedFrames, startInferences = depthPredictions
            let startMedia = elapsed
            let startClock = vlc?.clockDiagnostics ?? [:]
            let convertedStart = depthConvertedFrames
            let resetStart = depthSceneResets
            let backgroundPauseBefore = lastBackgroundPause
            depthInferenceSamples.removeAll(); depthAgeSamples.removeAll(); depthGainSamples.removeAll()
            depthDisplayTimes.removeAll(); depthGPUTimeSamples.removeAll()
            vlc?.beginFrameDiagnostics()
            try await pause(.seconds(10))
            let frameTrace = vlc?.endFrameDiagnostics() ?? []
            let submissionTrace = depthDisplayTimes
            let decoderTrace = vlc?.decoderDiagnostics() ?? []
            let usesSteadyClock = vlc?.usesSteadyClock ?? false
            let backgroundPausedDuringBenchmark = lastBackgroundPause != backgroundPauseBefore
            let seconds = ProcessInfo.processInfo.systemUptime - start
            let fps = Double(renderedFrames - startFrames) / seconds
            let times = depthInferenceSamples.sorted(), ages = depthAgeSamples.sorted()
            let gains = depthGainSamples.sorted()
            let sceneResets = depthSceneResets - resetStart
            let intervals = zip(depthDisplayTimes, depthDisplayTimes.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            let gpu = depthGPUTimeSamples.filter { $0 > 0 }.sorted()
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * fraction))]
            }
            checks.append(["name": "submission-cadence", "passed": intervals.count >= 240
                && percentile(intervals, 0.95) < 60 && (intervals.last ?? 1000) < 150,
                "intervalP95MS": percentile(intervals, 0.95), "maximumIntervalMS": intervals.last ?? 0])
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
            try await waitUntil { depthPredictions > highWarm + 8 || rendererError != nil }
            let highStart = ProcessInfo.processInfo.systemUptime, highFrames = renderedFrames
            let highConverted = depthConvertedFrames, highMedia = elapsed
            try await pause(.seconds(8))
            let highSeconds = ProcessInfo.processInfo.systemUptime - highStart
            let highFPS = Double(renderedFrames - highFrames) / highSeconds
            let highConvertedCount = depthConvertedFrames - highConverted
            checks.append(["name": "high-relief-sustained-conversion", "passed": highFPS >= 24 && highFPS <= 36
                && highConvertedCount > 160 && elapsed > highMedia + 6 && rendererError == nil && errorMessage == nil])
            depthStrength = 0.35; depthPopOut = 0.6
            let revision = depthRevision
            seek(to: 0.5)
            try await pause(.seconds(1))
            checks.append(["name": "seek-resets-depth-history", "passed": depthRevision > revision && elapsed > 14 && elapsed < 18])
            if isPlaying { togglePlayback() }
            try await pause(.milliseconds(500))
            var paused = elapsed
            try await pause(.milliseconds(700))
            let held = !isPlaying && abs(elapsed - paused) < 0.2
            let settledFrames = renderedFrames, settledPredictions = depthPredictions
            try await pause(.seconds(2))
            let pausedFrameUpdates = renderedFrames - settledFrames
            let pausedDepthUpdates = depthPredictions - settledPredictions
            checks.append(["name": "paused-picture-stays-static", "passed": pausedFrameUpdates == 0 && pausedDepthUpdates == 0
                && !isPlaying && abs(elapsed - paused) < 0.2])
            let oldFrames = renderedFrames
            depthStrength = 0
            try await waitUntil(seconds: 2) { renderedFrames > oldFrames }
            let zeroRedrew = renderedFrames > oldFrames
            let zeroFrames = renderedFrames
            depthStrength = 0.7
            try await waitUntil(seconds: 2) { renderedFrames > zeroFrames }
            checks.append(["name": "pause-and-strength-redraw", "passed": held && zeroRedrew && renderedFrames > zeroFrames && !isPlaying])
            let beforePop = renderedFrames
            depthPopOut = 1
            try await waitUntil(seconds: 2) { renderedFrames > beforePop }
            checks.append(["name": "paused-pop-out-redraw", "passed": renderedFrames > beforePop && !isPlaying && abs(elapsed - paused) < 0.2])
            depthStrength = 0.35
            var redraws = true
            for amount: Float in [0, 0.6, 1] {
                let before = renderedFrames
                depthPopOut = amount
                try await waitUntil(seconds: 2) { renderedFrames > before }
                redraws = redraws && renderedFrames > before && !isPlaying && abs(elapsed - paused) < 0.2
            }
            checks.append(["name": "paused-relief-sweep-keeps-position", "passed": redraws])
            // Let the preceding pop-out adjustment finish its depth prediction
            // before measuring the protection switch in isolation.
            let beforeProtectionSetup = renderedFrames
            depthPopOut = 0.6
            try await waitUntil(seconds: 3) { renderedFrames > beforeProtectionSetup }
            try await pause(.seconds(1))
            var protectionRedraws = renderedFrames > beforeProtectionSetup && !isPlaying
            var protectionSamples: [[String: Any]] = []
            for enabled in [false, true] {
                let before = renderedFrames, beforeDepth = depthPredictions
                depthProportionProtection = enabled
                try await waitUntil(seconds: 3) { renderedFrames > before }
                protectionRedraws = protectionRedraws && renderedFrames > before && !isPlaying && abs(elapsed - paused) < 0.2
                try await pause(.milliseconds(400))
                let stableFrames = renderedFrames, stableDepth = depthPredictions
                try await pause(.milliseconds(500))
                protectionRedraws = protectionRedraws && renderedFrames == stableFrames && depthPredictions == stableDepth && depthPredictions == beforeDepth
                protectionSamples.append(["enabled": enabled, "frameUpdates": renderedFrames - before,
                    "depthUpdates": depthPredictions - beforeDepth, "settledFrameUpdates": renderedFrames - stableFrames,
                    "settledDepthUpdates": depthPredictions - stableDepth, "playing": isPlaying])
            }
            checks.append(["name": "paused-proportion-protection-toggle-redraws-and-settles", "passed": protectionRedraws,
                           "samples": protectionSamples])
            var alignmentRedraws = true
            var alignmentSamples: [[String: Any]] = []
            for enabled in [!testedAlignment, testedAlignment] {
                let before = renderedFrames, predictions = depthPredictions
                depthMotionAlignment = enabled
                try await waitUntil(seconds: 3) { renderedFrames > before }
                try await pause(.milliseconds(400))
                let settled = renderedFrames
                try await pause(.milliseconds(500))
                alignmentRedraws = alignmentRedraws && renderedFrames > before && renderedFrames == settled
                    && depthPredictions == predictions && !isPlaying && abs(elapsed - paused) < 0.2
                alignmentSamples.append(["enabled": enabled, "frameUpdates": renderedFrames - before,
                    "depthUpdates": depthPredictions - predictions, "settledFrameUpdates": renderedFrames - settled])
            }
            checks.append(["name": "paused-motion-comparison-same-frame", "passed": alignmentRedraws, "samples": alignmentSamples])
            var edgeRedraws = true
            var edgeSamples: [[String: Any]] = []
            for enabled in [!testedEdges, testedEdges] {
                let before = renderedFrames, predictions = depthPredictions
                depthEdgeRefinement = enabled
                try await waitUntil(seconds: 3) { renderedFrames > before }
                try await pause(.milliseconds(400))
                let settled = renderedFrames
                try await pause(.milliseconds(500))
                edgeRedraws = edgeRedraws && renderedFrames > before && renderedFrames == settled
                    && depthPredictions == predictions && !isPlaying && abs(elapsed - paused) < 0.2
                edgeSamples.append(["enabled": enabled, "frameUpdates": renderedFrames - before,
                    "depthUpdates": depthPredictions - predictions, "settledFrameUpdates": renderedFrames - settled])
            }
            checks.append(["name": "paused-edge-comparison-same-frame", "passed": edgeRedraws, "samples": edgeSamples])
            var subjectRedraws = true
            var subjectSamples: [[String: Any]] = []
            for enabled in [!testedSubjects, testedSubjects] {
                let before = renderedFrames, predictions = depthPredictions
                depthSubjectAccuracy = enabled
                try await waitUntil(seconds: 5) { depthPredictions > predictions && renderedFrames > before }
                try await pause(.seconds(1))
                let settled = renderedFrames, settledDepth = depthPredictions
                try await pause(.milliseconds(600))
                subjectRedraws = subjectRedraws && renderedFrames > before && depthPredictions > predictions
                    && renderedFrames == settled && depthPredictions == settledDepth && !isPlaying && abs(elapsed - paused) < 0.2
                subjectSamples.append(["enabled": enabled, "frameUpdates": renderedFrames - before,
                    "depthUpdates": depthPredictions - predictions, "settledFrameUpdates": renderedFrames - settled])
            }
            checks.append(["name": "paused-subject-comparison-reinfers-and-settles", "passed": subjectRedraws, "samples": subjectSamples])
            let beforePausedSeek = renderedFrames
            seek(to: 0.2)
            try await waitUntil { renderedFrames > beforePausedSeek && abs(elapsed - 6) < 0.6 }
            let pausedSeekUpdated = renderedFrames > beforePausedSeek && abs(elapsed - 6) < 0.6 && !isPlaying
            try await pause(.seconds(1))
            paused = elapsed
            let seekSettledFrames = renderedFrames, seekSettledDepth = depthPredictions
            try await pause(.seconds(1))
            checks.append(["name": "paused-seek-updates-then-settles", "passed": pausedSeekUpdated
                && renderedFrames == seekSettledFrames && depthPredictions == seekSettledDepth && !isPlaying,
                "updated": pausedSeekUpdated, "elapsed": elapsed, "position": progress, "playing": isPlaying,
                "state": stateText, "framesSinceSeek": renderedFrames - beforePausedSeek,
                "settledFrameUpdates": renderedFrames - seekSettledFrames, "settledDepthUpdates": depthPredictions - seekSettledDepth])
            let beforeResume = depthPredictions
            if !isPlaying { togglePlayback() }
            let resumeStart = ProcessInfo.processInfo.systemUptime
            var resumeContinuous = true
            var resumeTrace: [[String: Any]] = []
            repeat {
                let age = ProcessInfo.processInfo.systemUptime - resumeStart
                resumeContinuous = resumeContinuous && elapsed >= paused - 0.25 && elapsed <= paused + age + 0.75
                resumeTrace.append(["age": age, "elapsed": elapsed, "clock": vlc?.clockDiagnostics ?? [:]])
                try await pause(.milliseconds(100))
            } while ProcessInfo.processInfo.systemUptime - resumeStart < 1.5
            checks.append(["name": "resume-conversion", "passed": resumeContinuous && isPlaying && elapsed > paused && elapsed < paused + 3.5 && depthPredictions > beforeResume,
                "continuous": resumeContinuous, "trace": resumeTrace,
                "elapsed": elapsed, "pausedElapsed": paused, "playing": isPlaying, "newDepthPredictions": depthPredictions - beforeResume, "clock": vlc?.clockDiagnostics ?? [:]])

            if ProcessInfo.processInfo.arguments.contains("--depth-resume-stress") {
                var rounds: [[String: Any]] = []
                for fraction in [0.2, 0.4, 0.1, 0.6, 0.2, 0.4, 0.1, 0.6] {
                    if isPlaying { togglePlayback() }
                    try await pause(.milliseconds(250))
                    let before = renderedFrames
                    seek(to: fraction)
                    try await waitUntil { !isPlaying && abs(elapsed - duration * fraction) < 0.6 && renderedFrames > before }
                    try await pause(.milliseconds(800))
                    let position = elapsed, initialClock = vlc?.clockDiagnostics ?? [:]
                    let began = ProcessInfo.processInfo.systemUptime
                    if !isPlaying { togglePlayback() }
                    var violations: [[String: Any]] = []
                    repeat {
                        let age = ProcessInfo.processInfo.systemUptime - began
                        if elapsed < position - 0.25 || elapsed > position + age + 0.75 {
                            violations.append(["age": age, "elapsed": elapsed, "clock": vlc?.clockDiagnostics ?? [:]])
                        }
                        try await pause(.milliseconds(50))
                    } while ProcessInfo.processInfo.systemUptime - began < 1.3
                    rounds.append(["position": position, "initialClock": initialClock, "endPosition": elapsed,
                        "violations": violations, "passed": violations.isEmpty && isPlaying && elapsed > position])
                }
                checks.append(["name": "repeated-paused-seek-resume", "rounds": rounds,
                    "passed": rounds.allSatisfy { $0["passed"] as? Bool == true }])
            }
            let beforeOff = elapsed
            setDepthConversion(false)
            expectedGeneration = diagnosticPlaybackGeneration
            await waitForPendingChange()
            try validateSource()
            try await waitUntil { elapsed >= beforeOff - 0.5 && isPlaying }
            checks.append(["name": "disable-preserves-position", "passed": request?.converts2D == false && elapsed >= beforeOff - 0.5 && isPlaying])
            setDepthConversion(true)
            expectedGeneration = diagnosticPlaybackGeneration
            await waitForPendingChange()
            try validateSource()
            try await waitUntil { depthPredictions > 5 }
            checks.append(["name": "reenable-conversion", "passed": request?.converts2D == true && depthPredictions > 5 && rendererError == nil])
            let report = smokeMetadata().merging([
                "sample": name, "engine": engine.rawValue, "depthMapping": testedSubjects ? "planar-coverage-v1" : "anchored-relief-v2", "projectionSampling": "proportion-protected-forward-v1", "proportionProtection": depthProportionProtection, "checks": checks, "popOut": depthPopOut, "screenWidthMeters": depthScreenWidthMeters,
                "benchmarkSeconds": seconds, "submittedFPS": fps,
                "vlcMonotonicClock": usesSteadyClock,
                "backgroundPausedDuringBenchmark": backgroundPausedDuringBenchmark,
                "vlcFrameTrace": frameTrace, "submissionTimes": submissionTrace, "decoderTrace": decoderTrace,
                "temporalPolicy": "motion-aware-cuts-continuous-history-v1",
                "subjectAccuracy": testedSubjects, "subjectAlgorithm": testedSubjects ? "aspect-near-tail-planar-v2" : "baseline-0.6.4",
                "edgeRefinement": testedEdges, "edgeAlgorithm": testedEdges ? "color-guided-depth-v1" : "baseline-0.6.3",
                "motionAlignment": testedAlignment, "motionAlgorithm": testedAlignment ? "bidirectional-patch-v1" : "baseline-0.6.2",
                "submissionIntervalP95MS": percentile(intervals, 0.95), "submissionMaximumIntervalMS": intervals.last ?? 0,
                "submissionGapsOver50MS": intervals.filter { $0 > 50 }.count,
                "gpuMeanMS": gpu.reduce(0, +) / Double(max(1, gpu.count)), "gpuP95MS": percentile(gpu, 0.95),
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
            writeReport(report)
        } catch {
            writeReport(smokeMetadata().merging(["sample": name, "passed": false, "cancelled": true,
                "error": "测试影片已切换或关闭，检查已停止，不操作后续影片", "checks": checks,
                "subjectAccuracy": testedSubjects, "subjectAlgorithm": testedSubjects ? "aspect-near-tail-planar-v2" : "baseline-0.6.4",
                "edgeRefinement": testedEdges, "motionAlignment": testedAlignment]) { _, new in new })
        }
    }

    private func writeDepthProbeReport(_ report: [String: Any], name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-\(name).json"), options: .atomic)
        }
    }
    #endif
}
