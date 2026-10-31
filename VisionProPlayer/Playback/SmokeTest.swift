import Foundation

extension PlayerModel {
    /// Development-only integration probe for the simulator and physical-device scripts.
    func runSmokeTestIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--smoke"), arguments.indices.contains(index + 1),
              request == nil else { return }
        let name = arguments[index + 1]
        if name == "lifecycle" { await runLifecycleProbe(); return }
        let configuration: (String, String, StereoLayout, PlaybackEngine)
        switch name {
        case "2d": configuration = ("Sample2D", "mp4", .flat, .native)
        case "mkv": configuration = ("SampleMKV", "mkv", .flat, .vlc)
        case "sbs-native": configuration = ("SampleSBS", "mp4", .fullSBS, .native)
        case "sbs-vlc": configuration = ("SampleSBS", "mkv", .fullSBS, .vlc)
        case "bbb-native": configuration = ("BBB-SBS-60s", "mp4", .fullSBS, .native)
        case "bbb-vlc": configuration = ("BBB-SBS-60s", "mkv", .fullSBS, .vlc)
        default: return
        }
        let isDownloadedClip = name.hasPrefix("bbb-")
        let sourceURL = isDownloadedClip
            ? URL.documentsDirectory.appending(path: "\(configuration.0).\(configuration.1)")
            : Bundle.main.url(forResource: configuration.0, withExtension: configuration.1)
        guard let url = sourceURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let expectedDuration = isDownloadedClip ? 60.0 : 12.0
        let expectedFrameSize = isDownloadedClip
            ? "1920 × 540 → 左右眼各 960 × 540"
            : "1280 × 360 → 左右眼各 640 × 360"
        layoutChoice = configuration.2; engineChoice = configuration.3
        open(url, layout: configuration.2, engine: configuration.3)
        // Wait for actual startup, with a bounded deadline. A missing frame is a failure for SBS.
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(100))
            if elapsed > 1.0 || errorMessage != nil { break }
        }
        let started = elapsed
        let canSeek = isSeekable
        seek(to: 0.5)
        try? await Task.sleep(for: .seconds(1))
        let afterSeek = elapsed
        if isPlaying { togglePlayback() }
        try? await Task.sleep(for: .milliseconds(400))
        let pausedTime = elapsed
        try? await Task.sleep(for: .milliseconds(700))
        let pauseHeld = !isPlaying && abs(elapsed - pausedTime) < 0.2
        if !isPlaying { togglePlayback() }
        try? await Task.sleep(for: .seconds(1))
        let resumed = isPlaying && elapsed > pausedTime
        let frames = renderedFrames
        let error = errorMessage ?? rendererError
        let success = started > 0 && canSeek
            && abs(duration - expectedDuration) < 0.2
            && afterSeek > expectedDuration / 2 - 1 && afterSeek < expectedDuration / 2 + 3
            && pauseHeld && resumed && error == nil
            && (!configuration.2.isStereo || (frames > 5 && frameSize == expectedFrameSize))
        let report: [String: Any] = smokeMetadata().merging([
            "sample": name, "engine": configuration.3.rawValue,
            "sourceFile": url.lastPathComponent,
            "startedSeconds": started, "durationSeconds": duration, "seekable": canSeek,
            "afterSeekSeconds": afterSeek, "pauseHeld": pauseHeld, "resumed": resumed,
            "submittedStereoFrames": frames, "frameSize": frameSize,
            "error": error as Any? ?? NSNull(), "passed": success,
            "scope": "Playback transport / frame submission only; stereo perception and audio require manual verification."
        ]) { _, new in new }
        do {
            let directory = URL.documentsDirectory
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appending(path: "smoke-\(name).json"), options: .atomic)
        } catch { print("Smoke report write failed: \(error)") }
        #endif
    }
    #if DEBUG
    private func smokeMetadata() -> [String: Any] {
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "physical-device"
        #endif
        let arguments = ProcessInfo.processInfo.arguments
        var runID = "unspecified"
        if let index = arguments.firstIndex(of: "--smoke-run-id"), arguments.indices.contains(index + 1) {
            runID = arguments[index + 1]
        }
        return ["environment": environment, "runID": runID,
                "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "timestamp": ISO8601DateFormatter().string(from: Date())]
    }

    private func runLifecycleProbe() async {
        var checks: [[String: Any]] = []
        for (file, ext, engine, layout) in [
            ("SampleMKV", "mkv", PlaybackEngine.vlc, StereoLayout.flat),
            ("SampleSBS", "mkv", .vlc, .fullSBS),
            ("SampleSBS", "mp4", .native, .fullSBS),
            ("SampleMKV", "mkv", .vlc, .flat)
        ] {
            guard let url = Bundle.main.url(forResource: file, withExtension: ext) else { return }
            open(url, layout: layout, engine: engine)
            await waitForPendingChange()
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(100))
                if elapsed > 0.5 || errorMessage != nil { break }
            }
            checks.append(["file": "\(file).\(ext)", "engine": engine.rawValue,
                "passed": elapsed > 0.5 && errorMessage == nil && rendererError == nil])
        }
        stop()
        await waitForPendingChange()
        let released = request == nil && nativePlayer == nil && vlc == nil && !isClosing
        let report: [String: Any] = smokeMetadata().merging(["sample": "lifecycle", "checks": checks,
            "released": released, "passed": released && checks.allSatisfy { $0["passed"] as? Bool == true }]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-lifecycle.json"), options: .atomic)
        }
    }
    #endif
}
