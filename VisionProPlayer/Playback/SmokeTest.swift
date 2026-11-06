import Foundation

extension PlayerModel {
    /// Development-only integration probe for the simulator and physical-device scripts.
    func runSmokeTestIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--product-demo") {
            for (name, title) in [("BBB-HEVC-2D-30s.mp4", "Big Buck Bunny"), ("BBB-SBS-60s.mp4", "Big Buck Bunny · 3D"), ("BBB-HEVC-2D-30s.mkv", "Big Buck Bunny · MKV"), ("ProductTracks.mp4", "字幕与双音轨演示")] {
                let url = URL.documentsDirectory.appending(path: name)
                if FileManager.default.fileExists(atPath: url.path) { _ = try? library.add(url, title: title) }
            }
        }
        if arguments.contains("--ou-demo") {
            let url = URL.documentsDirectory.appending(path: "BBB-Full-OU.mp4")
            if let film = try? library.add(url, title: "Big Buck Bunny · 上下 3D") { openFilm(film) }
        }
        guard let index = arguments.firstIndex(of: "--smoke"), arguments.indices.contains(index + 1),
              request == nil else { return }
        let name = arguments[index + 1]
        if name == "track-preferences" { Task { await runTrackPreferenceProbe() }; return }
        if name == "depth-presets" { Task { await runDepthPresetProbe() }; return }
        if name == "seek-preview-film" {
            guard let index = arguments.firstIndex(of: "--film-id"), arguments.indices.contains(index + 1),
                  let id = UUID(uuidString: arguments[index + 1]), let film = library.film(id) else { return }
            Task { await runSeekPreviewFilmProbe(film) }
            return
        }
        if name == "seek-preview" { Task { await runSeekPreviewProbe() }; return }
        if name == "product" { Task { await runProductProbe() }; return }
        if name.hasPrefix("depth-endurance-") { Task { await runDepthEnduranceProbe(name: name) }; return }
        if name.hasPrefix("depth-") {
            Task { await runDepthProbe(name: name) }
            return
        }
        if name == "lifecycle" { await runLifecycleProbe(); return }
        if name == "routing" { await runRoutingProbe(); return }
        let compatibility = CompatibilitySample(rawValue: name)
        let configuration: (String, String, StereoLayout, PlaybackEngine)
        switch name {
        case "ou-native": configuration = ("BBB-Full-OU", "mp4", .fullOU, .native)
        case "ou-vlc": configuration = ("BBB-Full-OU", "mp4", .fullOU, .vlc)
        case "half-ou-native": configuration = ("BBB-Half-OU", "mp4", .halfOU, .native)
        case "half-ou-vlc": configuration = ("BBB-Half-OU", "mp4", .halfOU, .vlc)
        case "2d": configuration = ("Sample2D", "mp4", .flat, .native)
        case "mkv": configuration = ("SampleMKV", "mkv", .flat, .vlc)
        case "sbs-native": configuration = ("SampleSBS", "mp4", .fullSBS, .native)
        case "sbs-vlc": configuration = ("SampleSBS", "mkv", .fullSBS, .vlc)
        case "bbb-native": configuration = ("BBB-SBS-60s", "mp4", .fullSBS, .native)
        case "bbb-vlc": configuration = ("BBB-SBS-60s", "mkv", .fullSBS, .vlc)
        default:
            guard let compatibility else { return }
            configuration = (compatibility.fileStem, compatibility.fileExtension, compatibility.layout, compatibility.engine)
        }
        let isOU = name.contains("ou-")
        let isDownloadedClip = name.hasPrefix("bbb-") || compatibility != nil || isOU
        let sourceURL = isDownloadedClip
            ? URL.documentsDirectory.appending(path: "\(configuration.0).\(configuration.1)")
            : Bundle.main.url(forResource: configuration.0, withExtension: configuration.1)
        guard let url = sourceURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let expectedDuration = isOU ? 33.843 : compatibility != nil ? 30.0 : (isDownloadedClip ? 60.0 : 12.0)
        let expectedFrameSize = isOU
            ? (configuration.2 == .halfOU ? "1920 × 1080 → 左右眼各 1920 × 540" : (configuration.3 == .native ? "1920 × 2160 → 左右眼各 1920 × 1080" : "1706 × 1920 → 左右眼各 1706 × 960"))
            : compatibility != nil ? "1920 × 1080 → 左右眼各 960 × 1080"
            : (isDownloadedClip ? "1920 × 540 → 左右眼各 960 × 540" : "1280 × 360 → 左右眼各 640 × 360")
        eyeCheck = false; swapEyes = false
        layoutChoice = configuration.2; engineChoice = configuration.3
        open(url, layout: configuration.2, engine: configuration.3)
        // Wait for actual startup, with a bounded deadline. A missing frame is a failure for SBS.
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(100))
            if elapsed > 1.0 || errorMessage != nil { break }
        }
        let started = elapsed
        let framesAtStart = renderedFrames
        let canSeek = isSeekable
        seek(to: 0.5)
        try? await Task.sleep(for: .seconds(1))
        let afterSeek = elapsed
        let framesAfterSeek = renderedFrames
        if isPlaying { togglePlayback() }
        try? await Task.sleep(for: .milliseconds(400))
        let pausedTime = elapsed
        try? await Task.sleep(for: .milliseconds(700))
        let pauseHeld = !isPlaying && abs(elapsed - pausedTime) < 0.2
        let pausedEndTime = elapsed
        let framesBeforeResume = renderedFrames
        if !isPlaying { togglePlayback() }
        try? await Task.sleep(for: .seconds(1))
        let resumed = isPlaying && elapsed > pausedTime
        let frames = renderedFrames
        let error = errorMessage ?? rendererError
        let success = started > 0 && canSeek
            && abs(duration - expectedDuration) < 0.2
            && afterSeek > expectedDuration / 2 - 1 && afterSeek < expectedDuration / 2 + 3
            && pauseHeld && resumed && error == nil
            && (!configuration.2.isStereo || (frames > 5 && frameSize == expectedFrameSize
                && framesAfterSeek > framesAtStart && frames > framesBeforeResume
                && abs(stereoDisplayAspect - 16.0 / 9.0) < 0.01))
        let report: [String: Any] = smokeMetadata().merging([
            "sample": name, "engine": configuration.3.rawValue,
            "sourceFile": url.lastPathComponent,
            "layout": configuration.2.rawValue, "displayAspect": stereoDisplayAspect,
            "startedSeconds": started, "durationSeconds": duration, "seekable": canSeek,
            "afterSeekSeconds": afterSeek, "pauseHeld": pauseHeld, "resumed": resumed,
            "pausedStartSeconds": pausedTime, "pausedEndSeconds": pausedEndTime,
            "framesAtStart": framesAtStart, "framesAfterSeek": framesAfterSeek,
            "framesBeforeResume": framesBeforeResume,
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
    private func runRoutingProbe() async {
        var checks: [[String: Any]] = []
        func record(_ check: [String: Any]) {
            checks.append(check.merging(["engine": request?.engine.rawValue ?? "none",
                "layout": request?.layout.rawValue ?? "none", "frames": renderedFrames,
                "frameSize": frameSize, "aspect": stereoDisplayAspect, "notice": playbackNotice ?? "",
                "error": errorMessage ?? rendererError ?? "", "state": stateText,
                "timestamp": ISO8601DateFormatter().string(from: Date())]) { old, _ in old })
            let progress = smokeMetadata().merging(["checks": checks, "state": stateText,
                "engine": request?.engine.rawValue ?? "none", "error": errorMessage ?? ""]) { _, new in new }
            if let data = try? JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL.documentsDirectory.appending(path: "routing-progress.json"), options: .atomic)
            }
        }
        func waitUntil(_ predicate: () -> Bool) async {
            for _ in 0..<100 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let sample = Bundle.main.url(forResource: "SampleSBS", withExtension: "mp4") else { return }
        engineChoice = .automatic; layoutChoice = .flat
        openSample(sample, layout: .fullSBS, engine: .native)
        await waitForPendingChange()
        await waitUntil { elapsed > 0.5 }
        record(["name": "sample-preserves-user-preferences", "passed":
            engineChoice == .automatic && layoutChoice == .flat && request?.engine == .native
            && request?.layout == .fullSBS && renderedFrames > 0])

        open(URL.documentsDirectory.appending(path: "FallbackProbe.avi"))
        await waitForPendingChange()
        await waitUntil { elapsed > 1 || errorMessage != nil }
        record(["name": "avi-routes-directly-to-vlc-in-2d", "passed":
            request?.engine == .vlc && request?.layout == .flat && elapsed > 1
            && errorMessage == nil && playbackNotice == nil])

        // An AVI/DivX fixture with an MP4 suffix forces a real AVPlayer failure.
        open(URL.documentsDirectory.appending(path: "FallbackProbe.mp4"))
        await waitForPendingChange()
        let beganWithNative = request?.engine == .native || isSwitchingEngine
        await waitUntil { request?.engine == .vlc && elapsed > 1 }
        let didFallback = request?.engine == .vlc && playbackNotice != nil && elapsed > 1 && errorMessage == nil
        seek(to: 0.5)
        try? await Task.sleep(for: .seconds(1))
        let sought = elapsed > 5 && elapsed < 9
        if isPlaying { togglePlayback() }
        try? await Task.sleep(for: .milliseconds(500))
        let paused = elapsed
        try? await Task.sleep(for: .milliseconds(500))
        let held = !isPlaying && abs(elapsed - paused) < 0.2
        if !isPlaying { togglePlayback() }
        try? await Task.sleep(for: .seconds(1))
        record(["name": "native-failure-falls-back-once-and-controls-work", "beganWithNative": beganWithNative,
            "fallbackNotice": playbackNotice ?? "", "seekWorked": sought, "pauseHeld": held,
            "passed": beganWithNative && didFallback && sought && held && isPlaying && elapsed > paused])

        open(URL.documentsDirectory.appending(path: "FallbackProbe.mp4"), layout: .halfSBS)
        await waitForPendingChange()
        await waitUntil { request?.engine == .vlc && renderedFrames > 5 }
        record(["name": "fallback-preserves-stereo-layout", "passed":
            request?.engine == .vlc && request?.layout == .halfSBS && renderedFrames > 5
            && frameSize == "960 × 540 → 左右眼各 480 × 540" && abs(stereoDisplayAspect - 16.0 / 9.0) < 0.01
            && errorMessage == nil && rendererError == nil && playbackNotice != nil])

        open(URL.documentsDirectory.appending(path: "deliberately-missing-routing-probe.mp4"))
        await waitForPendingChange()
        await waitUntil { request?.engine == .vlc && errorMessage != nil }
        let failedID = request?.id
        try? await Task.sleep(for: .seconds(1))
        record(["name": "both-engines-fail-without-retry-loop", "passed":
            request?.id == failedID && request?.engine == .vlc && errorMessage != nil && !isSwitchingEngine])

        open(URL.documentsDirectory.appending(path: "FallbackProbe.mp4"))
        await waitForPendingChange()
        stop()
        await waitForPendingChange()
        try? await Task.sleep(for: .milliseconds(500))
        record(["name": "stop-cancels-pending-native-failure", "passed":
            request == nil && vlc == nil && nativePlayer == nil && !isSwitchingEngine])

        open(URL.documentsDirectory.appending(path: "FallbackProbe.mp4"))
        await waitForPendingChange()
        openSample(sample, layout: .fullSBS, engine: .native)
        await waitForPendingChange()
        await waitUntil { renderedFrames > 5 }
        record(["name": "new-file-wins-over-stale-failure", "passed":
            request?.url == sample && request?.engine == .native && renderedFrames > 5 && playbackNotice == nil
            && engineChoice == .automatic && layoutChoice == .flat])
        let report = smokeMetadata().merging(["sample": "routing", "checks": checks,
            "passed": checks.allSatisfy { $0["passed"] as? Bool == true }]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-routing.json"), options: .atomic)
        }
    }

    func smokeMetadata() -> [String: Any] {
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
