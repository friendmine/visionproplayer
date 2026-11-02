import Foundation

#if DEBUG
extension PlayerModel {
    /// Bounded continuous playback probe. Leaving this movie stops the probe;
    /// it never reopens media or overrides the user's next playback request.
    func runDepthEnduranceProbe(name: String) async {
        let engine: PlaybackEngine = name.hasSuffix("vlc") ? .vlc : .native
        depthMotionAlignment = !ProcessInfo.processInfo.arguments.contains("--depth-motion-baseline")
        depthEdgeRefinement = depthMotionAlignment && !ProcessInfo.processInfo.arguments.contains("--depth-reference-063")
        let alignment = depthMotionAlignment
        let edges = depthEdgeRefinement
        let source = URL.documentsDirectory.appending(path: engine == .vlc ? "BBB-Motion-2D-30s.mkv" : "BBB-Motion-2D-30s.mp4")
        depthStrength = 0.35; depthPopOut = 0.6; depthProportionProtection = true
        openSample(source, layout: .flat, engine: engine, convert2D: true)
        await waitForPendingChange()
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 45
        while depthPredictions < 8 && errorMessage == nil && rendererError == nil && ProcessInfo.processInfo.systemUptime < startupDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let identity = request?.id
        let start = ProcessInfo.processInfo.systemUptime
        var segmentStart = start, segmentFrames = renderedFrames
        var seekWindows: [(Double, Double)] = []
        var segments: [[String: Any]] = []
        var recentStates: [[String: Any]] = []
        var lastFrameTime = start
        var failure: String?
        var peakThermal = ProcessInfo.processInfo.thermalState.rawValue
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        func write(_ report: [String: Any], suffix: String) {
            if let data = try? JSONSerialization.data(withJSONObject: smokeMetadata().merging(report) { _, new in new }, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL.documentsDirectory.appending(path: "smoke-\(name)\(suffix).json"), options: .atomic)
            }
        }
        if depthPredictions < 8 || identity == nil { failure = errorMessage ?? rendererError ?? "深度播放未启动" }
        depthDisplayTimes.removeAll(); depthGPUTimeSamples.removeAll()
        while failure == nil && ProcessInfo.processInfo.systemUptime - start < 1200 && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = ProcessInfo.processInfo.systemUptime
            if let latest = depthDisplayTimes.last { lastFrameTime = max(lastFrameTime, latest) }
            recentStates.append(["age": now - start, "mediaTime": elapsed, "progress": progress,
                "duration": duration, "playing": isPlaying, "state": stateText,
                "frames": renderedFrames, "predictions": depthPredictions,
                "lastFrameAge": now - lastFrameTime, "strength": depthStrength,
                "backgroundPauseAge": lastBackgroundPause.map { now - $0 } ?? -1,
                "clock": vlc?.clockDiagnostics ?? [:]])
            if recentStates.count > 15 { recentStates.removeFirst() }
            if request?.id != identity { failure = "用户离开测试影片，检查已停止"; break }
            if let error = errorMessage ?? rendererError { failure = error; break }
            // Segment statistics are cleared every 30 seconds; the watchdog
            // must retain the actual last frame across those boundaries.
            if now - lastFrameTime > 5 { failure = "连续五秒无新画面，可能锁定或停止播放"; break }
            if progress > 0.85 && isPlaying {
                seekWindows.append((now, now + 1))
                seek(to: 0.03)
            }
            peakThermal = max(peakThermal, ProcessInfo.processInfo.thermalState.rawValue)
            if now - segmentStart >= 30 {
                let times = depthDisplayTimes.filter { $0 >= segmentStart }
                let pairs = zip(times, times.dropFirst())
                let intervals = pairs.compactMap { a, b -> Double? in
                    // Report loop seeks separately from ordinary frame cadence.
                    if seekWindows.contains(where: { a <= $0.1 && b >= $0.0 }) { return nil }
                    return (b - a) * 1000
                }
                let fps = Double(renderedFrames - segmentFrames) / (now - segmentStart)
                let interval95 = percentile(intervals, 0.95), maximum = intervals.max() ?? 0
                let gpu = depthGPUTimeSamples.filter { $0 > 0 }
                let passed = fps >= 24 && fps <= 36 && intervals.count > 600 && interval95 < 60 && maximum < 150
                segments.append(["elapsedSeconds": now - start, "submittedFPSIncludingSeeks": fps,
                    "ordinaryIntervalP95MS": interval95, "ordinaryMaximumIntervalMS": maximum,
                    "intervalSamples": intervals.count, "excludedSeekIntervals": max(0, times.count - 1 - intervals.count),
                    "gpuP95MS": percentile(gpu, 0.95), "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "passed": passed])
                write(["sample": name, "motionAlignment": alignment, "edgeRefinement": edges, "elapsedSeconds": now - start,
                    "completedSegments": segments.count, "latestSegment": segments.last!], suffix: "-progress")
                segmentStart = now; segmentFrames = renderedFrames
                depthDisplayTimes.removeAll(); depthGPUTimeSamples.removeAll()
            }
        }
        let duration = ProcessInfo.processInfo.systemUptime - start
        let passed = failure == nil && !Task.isCancelled && duration >= 1200 && segments.count >= 39
            && segments.allSatisfy { $0["passed"] as? Bool == true }
        write(["sample": name, "sourceFile": source.lastPathComponent, "motionAlignment": alignment, "edgeRefinement": edges,
            "motionAlgorithm": alignment ? "bidirectional-patch-v1" : "baseline-0.6.2",
            "durationSeconds": duration, "segments": segments, "loopSeeks": seekWindows.count,
            "recentStates": recentStates,
            "maximumThermalState": peakThermal, "passed": passed, "error": failure ?? "",
            "scope": "20-minute repeated motion fixture; submission cadence and GPU timing, not scanout or human perception. One-second intervals around intentional loop seeks excluded from ordinary cadence, but included in segment FPS."], suffix: "")
    }
}
#endif
