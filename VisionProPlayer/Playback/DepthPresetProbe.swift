import Foundation

extension PlayerModel {
    #if DEBUG
    func runDepthPresetProbe() async {
        var checks: [[String: Any]] = []
        var failure: String?
        var owned: [UUID] = []
        let originalDefault = library.defaultDepthEffect
        let folder = URL.temporaryDirectory.appending(path: "depth-preset-\(UUID().uuidString)")
        let suite = "depth-preset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func wait(_ predicate: () -> Bool) async {
            for _ in 0..<150 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let nativeURL = folder.appending(path: "preset-native.mp4")
            let vlcURL = folder.appending(path: "preset-vlc.mkv")
            try FileManager.default.copyItem(at: .documentsDirectory.appending(path: "BBB-HEVC-2D-30s.mp4"), to: nativeURL)
            try FileManager.default.copyItem(at: .documentsDirectory.appending(path: "BBB-HEVC-2D-30s.mkv"), to: vlcURL)
            let root = folder.appending(path: "store")
            let store = MediaLibrary(root: root, defaults: defaults)
            check("factory-default-natural", store.defaultDepthEffect == .natural)
            let beforeDefault = try store.add(URL(string: "https://example.invalid/existing.mp4")!)
            store.saveDefaultDepthEffect(.foreground)
            check("existing-film-keeps-original-effect", store.film(beforeDefault.id)?.preferences.depthEffect == .natural)
            let newLocal = try store.add(nativeURL)
            check("new-local-inherits-foreground-with-ai-off", newLocal.preferences.depthEffect == .foreground && !newLocal.preferences.converts2D)
            let custom = DepthEffect(strength: 0.52, popOut: 0.27, proportionProtection: false, preset: .custom)
            store.saveDefaultDepthEffect(custom)
            let duplicate = try store.add(nativeURL)
            check("reimport-preserves-film-override", duplicate.id == newLocal.id && duplicate.preferences.depthEffect == .foreground)
            let network = try store.add(URL(string: "https://example.invalid/new.mp4")!)
            check("network-inherits-custom", network.preferences.depthEffect == custom && !network.preferences.converts2D)
            let transfer = try PhotoVideoTransfer.stage(nativeURL)
            let photo = try store.importPhoto(transfer)
            check("photo-inherits-custom", photo.preferences.depthEffect == custom && !photo.preferences.converts2D)
            let reopened = MediaLibrary(root: root, defaults: defaults)
            check("default-and-film-effects-survive-relaunch", reopened.defaultDepthEffect == custom
                  && reopened.film(newLocal.id)?.preferences.depthEffect == .foreground
                  && reopened.film(photo.id)?.preferences.depthEffect == custom)
            let legacy = try JSONDecoder().decode(FilmPreferences.self, from: Data(#"{"layout":"flat","converts2D":true,"strength":0.72,"popOut":0.8,"proportionProtection":false,"swapped":false,"subtitleOffset":0}"#.utf8))
            let legacyRoot = folder.appending(path: "legacy-store")
            try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
            var legacyFilm = LibraryFilm(title: "Legacy fixture", location: nativeURL.absoluteString)
            legacyFilm.preferences = legacy
            try JSONEncoder().encode([legacyFilm]).write(to: legacyRoot.appending(path: "library.json"))
            let oldStore = MediaLibrary(root: legacyRoot, defaults: defaults)
            check("legacy-film-keeps-tuned-effect", oldStore.film(legacyFilm.id)?.preferences == legacy
                  && legacy.depthEffect == DepthEffect(strength: 0.72, popOut: 0.8, proportionProtection: false))
            let oldest = try JSONDecoder().decode(FilmPreferences.self, from: Data(#"{"layout":"flat","converts2D":false,"strength":0.35,"swapped":false,"subtitleOffset":0}"#.utf8))
            check("oldest-film-keeps-balanced-effect", oldest.depthEffect == .natural)
            let invalid = Data(#"{"strength":2,"popOut":-1,"proportionProtection":true,"preset":"foreground"}"#.utf8)
            defaults.set(invalid, forKey: "defaultDepthEffect")
            let bounded = MediaLibrary(root: root, defaults: defaults).defaultDepthEffect
            check("stored-out-of-range-default-is-bounded", bounded.strength == 1 && bounded.popOut == 0 && bounded.preset == .custom)
            defaults.set(Data("invalid".utf8), forKey: "defaultDepthEffect")
            check("unreadable-default-falls-back-to-natural", MediaLibrary(root: root, defaults: defaults).defaultDepthEffect == .natural)

            for (engine, url) in [(PlaybackEngine.native, nativeURL), (.vlc, vlcURL)] {
                let film = try library.add(url, title: "Temporary preset probe")
                owned.append(film.id)
                library.update(film.id) { $0.preferences.depthEffect = .natural; $0.preferences.converts2D = true }
                openFilm(library.film(film.id)!)
                await waitForPendingChange()
                await wait { isPlaying && depthPredictions > 5 && renderedFrames > 5 }
                check("\(engine.rawValue)-ai-started", request?.engine == engine && isPlaying && depthPredictions > 5)
                let requestID = request?.id
                for preset in [DepthPreset.natural, .foreground] {
                    selectDepthPreset(preset)
                    let frameStart = renderedFrames, mediaStart = elapsed
                    let start = ProcessInfo.processInfo.systemUptime
                    try await Task.sleep(for: .seconds(4))
                    let fps = Double(renderedFrames - frameStart) / (ProcessInfo.processInfo.systemUptime - start)
                    check("\(engine.rawValue)-\(preset.rawValue)-playing", request?.id == requestID
                          && currentDepthEffect == (preset == .natural ? .natural : .foreground)
                          && fps >= 24 && fps <= 36 && elapsed > mediaStart + 3
                          && rendererError == nil && errorMessage == nil)
                    checks[checks.count - 1]["submittedFPS"] = fps
                }
                if isPlaying { togglePlayback() }
                await wait { !isPlaying }
                try await Task.sleep(for: .milliseconds(500))
                let paused = elapsed
                for preset in [DepthPreset.natural, .foreground] {
                    // Paused redraws reuse the last decoded buffer, so only
                    // renderedFrames counts the actual display update here.
                    let before = renderedFrames
                    selectDepthPreset(preset)
                    await wait { renderedFrames > before }
                    check("\(engine.rawValue)-paused-\(preset.rawValue)-updates-picture", !isPlaying && abs(elapsed - paused) < 0.3
                          && renderedFrames > before && request?.id == requestID)
                    checks[checks.count - 1]["framesSubmitted"] = renderedFrames - before
                    checks[checks.count - 1]["positionDelta"] = elapsed - paused
                    try await Task.sleep(for: .milliseconds(500))
                    let settled = renderedFrames
                    try await Task.sleep(for: .milliseconds(500))
                    check("\(engine.rawValue)-paused-\(preset.rawValue)-settles", renderedFrames == settled && !isPlaying)
                }
                selectDepthPreset(.custom)
                check("\(engine.rawValue)-custom-selection-keeps-values", currentDepthEffect.preset == .custom
                      && depthStrength == 0.35 && depthPopOut == 0.6 && depthProportionProtection)
                let beforeCustom = renderedFrames
                depthStrength = 0.45; depthPopOut = 0.2; savePicturePreferences()
                await wait { renderedFrames > beforeCustom }
                check("\(engine.rawValue)-paused-custom-updates-picture", renderedFrames > beforeCustom && !isPlaying && abs(elapsed - paused) < 0.3)
                let saved = currentDepthEffect
                returnToLibrary(); await waitForPendingChange()
                openFilm(library.film(film.id)!)
                await waitForPendingChange()
                await wait { isPlaying && renderedFrames > 5 }
                check("\(engine.rawValue)-custom-survives-reopen", currentDepthEffect == saved && request?.converts2D == true)
                if isPlaying { togglePlayback() }
                await wait { !isPlaying }
                setCinema(true); await waitForPendingChange()
                await wait { duration > 0 }
                check("\(engine.rawValue)-cinema-preserves-effect", request?.isCinema == true && currentDepthEffect == saved)
                setCinema(false); await waitForPendingChange()
                await wait { renderedFrames > 0 }
                check("\(engine.rawValue)-window-return-preserves-effect", request?.isCinema == false && currentDepthEffect == saved)
                let filmBeforeSample = library.film(film.id)?.preferences
                openSample(url, layout: .flat, engine: engine, convert2D: true)
                await waitForPendingChange()
                selectDepthPreset(.foreground)
                check("\(engine.rawValue)-diagnostic-keeps-film-and-defaults", library.film(film.id)?.preferences == filmBeforeSample
                      && library.defaultDepthEffect == originalDefault)
                returnToLibrary(); await waitForPendingChange()
            }
        } catch { failure = error.localizedDescription }
        returnToLibrary(); await waitForPendingChange()
        for id in owned { library.remove(id) }
        try? FileManager.default.removeItem(at: folder)
        let report = smokeMetadata().merging([
            "sample": "depth-presets", "checks": checks, "error": failure ?? "",
            "passed": failure == nil && !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Preset application, legacy and new film persistence, isolated default storage, photo/network/local imports, native/VLC short playback, paused update and cinema session settings. UI comfort and perceived depth require wearer confirmation."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-depth-presets.json"), options: .atomic)
        }
    }
    #endif
}
