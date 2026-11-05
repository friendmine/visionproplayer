import Foundation
import AVFoundation

extension PlayerModel {
    #if DEBUG
    func runProductProbe() async {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func wait(_ seconds: Double = 10, _ predicate: () -> Bool) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate() && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let folder = URL.temporaryDirectory.appending(path: "product-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        var owned: [UUID] = []
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suite = "product-probe-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let focus = FocusPlayback()
            focus.reveal(at: 0)
            focus.update(enabled: true, playing: true, blocked: false, at: 2.9)
            let beforeDeadline = focus.visible
            focus.update(enabled: true, playing: true, blocked: false, at: 3.1)
            check("focus-hides-after-idle", beforeDeadline && !focus.visible)
            focus.reveal(at: 4)
            check("focus-interaction-restores-controls", focus.visible)
            focus.hold("menu", true, at: 4)
            focus.hold("slider", true, at: 4)
            focus.hold("menu", false, at: 5)
            focus.update(enabled: true, playing: true, blocked: false, at: 20)
            let held = focus.visible
            focus.hold("slider", false, at: 20)
            focus.update(enabled: true, playing: true, blocked: false, at: 22.9)
            let releaseDelay = focus.visible
            focus.update(enabled: true, playing: true, blocked: false, at: 23.1)
            check("focus-overlapping-interactions-hold-and-restart-timer", held && releaseDelay && !focus.visible)
            focus.update(enabled: true, playing: false, blocked: false, at: 24)
            let pausedVisible = focus.visible
            focus.update(enabled: true, playing: true, blocked: true, at: 40)
            let errorVisible = focus.visible
            focus.update(enabled: false, playing: true, blocked: false, at: 60)
            check("focus-pause-errors-and-disabled-mode-stay-visible", pausedVisible && errorVisible && focus.visible)
            let legacyPreferences = try JSONDecoder().decode(FilmPreferences.self, from: Data(#"{"layout":"flat","converts2D":false,"strength":0.35,"swapped":false,"subtitleOffset":0}"#.utf8))
            check("legacy-library-defaults-to-balanced-pop-out", legacyPreferences.popOut == nil && legacyPreferences.strength == 0.35)
            check("legacy-library-enables-proportion-protection", legacyPreferences.proportionProtection ?? true)
            let store = MediaLibrary(root: folder.appending(path: "store"), defaults: defaults)
            store.externalCaptionSize = .large
            store.externalCaptionAtTop = true
            let reopened = MediaLibrary(root: folder.appending(path: "store"), defaults: defaults)
            check("caption-appearance-survives-relaunch", reopened.externalCaptionSize == .large && reopened.externalCaptionAtTop)
            let nativeURL = folder.appending(path: "product-native.mp4")
            let vlcURL = folder.appending(path: "product-vlc.mkv")
            try FileManager.default.copyItem(at: .documentsDirectory.appending(path: "ProductTracks.mp4"), to: nativeURL)
            try FileManager.default.copyItem(at: .documentsDirectory.appending(path: "ProductTracks.mkv"), to: vlcURL)
            let photoRoot = folder.appending(path: "photo-store")
            let photoStore = MediaLibrary(root: photoRoot, defaults: defaults)
            var transfer: PhotoVideoTransfer? = try PhotoVideoTransfer.stage(nativeURL)
            let photo = try photoStore.importPhoto(transfer!)
            transfer = nil
            let photoURL = try photoStore.resolve(photo)
            check("photo-import-preserves-video-bytes", try Data(contentsOf: photoURL) == Data(contentsOf: nativeURL) && photo.photoFile != nil)
            let localHistory = try photoStore.add(nativeURL)
            let networkHistory = try photoStore.add(URL(string: "https://example.com/history.mp4")!)
            for id in [photo.id, localHistory.id, networkHistory.id] {
                photoStore.update(id) {
                    $0.lastOpened = Date(); $0.position = 5; $0.duration = 12
                    $0.favorite = true; $0.preferences.strength = 0.6
                }
            }
            let expectedAfterClear = photoStore.films.map { film in
                var copy = film; copy.lastOpened = nil; copy.position = 0; return copy
            }
            try photoStore.clearWatchHistory()
            let clearedStore = MediaLibrary(root: photoRoot, defaults: defaults)
            check("history-clear-persists-and-preserves-library", !clearedStore.hasWatchHistory && clearedStore.films == expectedAfterClear && FileManager.default.isReadableFile(atPath: photoURL.path))
            photoStore.updateProgress(photo.id, seconds: 9, duration: 12)
            check("history-clear-rejects-delayed-progress", photoStore.films == expectedAfterClear && MediaLibrary(root: photoRoot, defaults: defaults).films == expectedAfterClear)
            photoStore.update(photo.id) { $0.lastOpened = Date() }
            photoStore.updateProgress(photo.id, seconds: 3, duration: 12)
            check("history-new-viewing-records-progress", photoStore.hasWatchHistory && MediaLibrary(root: photoRoot, defaults: defaults).film(photo.id)?.position == 3)
            let beforeFailure = photoStore.films
            let unavailableRoot = folder.appending(path: "unavailable-photo-store")
            try FileManager.default.moveItem(at: photoRoot, to: unavailableRoot)
            try Data("block store writes".utf8).write(to: photoRoot)
            var clearFailed = false
            do { try photoStore.clearWatchHistory() } catch { clearFailed = true }
            check("history-clear-storage-failure-preserves-records", clearFailed && photoStore.films == beforeFailure && MediaLibrary(root: unavailableRoot, defaults: defaults).films == beforeFailure)
            try FileManager.default.removeItem(at: photoRoot)
            try FileManager.default.moveItem(at: unavailableRoot, to: photoRoot)
            let movedRoot = folder.appending(path: "moved-photo-store")
            try FileManager.default.moveItem(at: photoRoot, to: movedRoot)
            let movedPhotos = MediaLibrary(root: movedRoot, defaults: defaults)
            let relocatedPhotoURL = try movedPhotos.resolve(movedPhotos.film(photo.id)!)
            check("photo-import-survives-container-move", FileManager.default.isReadableFile(atPath: relocatedPhotoURL.path))
            movedPhotos.remove(photo.id)
            check("photo-remove-keeps-original", !FileManager.default.fileExists(atPath: relocatedPhotoURL.path) && FileManager.default.isReadableFile(atPath: nativeURL.path))
            var abandoned: PhotoVideoTransfer? = try PhotoVideoTransfer.stage(nativeURL)
            let abandonedURL = abandoned!.url
            abandoned = nil
            check("photo-cancel-cleans-staging", !FileManager.default.fileExists(atPath: abandonedURL.path))
            let first = try store.add(nativeURL)
            let duplicate = try store.add(nativeURL)
            check("library-deduplicates", first.id == duplicate.id && store.films.count == 1)
            store.update(first.id) { $0.location = folder.appending(path: "old-container/product-native.mp4").absoluteString }
            let relocatedDuplicate = try store.add(nativeURL)
            check("bookmark-deduplicates-relocated-container", relocatedDuplicate.id == first.id && store.films.count == 1)
            let damagedRoot = folder.appending(path: "damaged")
            try FileManager.default.createDirectory(at: damagedRoot, withIntermediateDirectories: true)
            let damagedData = Data("incomplete-json".utf8)
            try damagedData.write(to: damagedRoot.appending(path: "library.json"))
            let recovered = MediaLibrary(root: damagedRoot, defaults: defaults)
            _ = try recovered.add(nativeURL)
            let backups = try FileManager.default.contentsOfDirectory(at: damagedRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("library-recovery-") }
            check("damaged-library-preserved-before-save", try backups.count == 1 && Data(contentsOf: backups[0]) == damagedData)
            store.update(first.id) { $0.favorite = true; $0.position = 3; $0.duration = 12; $0.preferences.strength = 0.62; $0.preferences.popOut = 0.6; $0.preferences.proportionProtection = false; $0.preferences.layout = .halfSBS }
            let reloaded = MediaLibrary(root: folder.appending(path: "store"), defaults: defaults)
            check("library-persists-progress-favorite-settings", reloaded.film(first.id)?.favorite == true && reloaded.film(first.id)?.position == 3 && reloaded.film(first.id)?.preferences.strength == 0.62 && reloaded.film(first.id)?.preferences.popOut == 0.6 && reloaded.film(first.id)?.preferences.proportionProtection == false)
            check("bookmark-resolves", try reloaded.resolve(first).path == nativeURL.path)
            let second = try reloaded.add(vlcURL)
            check("per-film-settings-isolated", reloaded.film(second.id)?.preferences.layout == .flat && reloaded.film(second.id)?.preferences.strength == 0.35 && reloaded.film(second.id)?.preferences.popOut == nil && (reloaded.film(second.id)?.preferences.proportionProtection ?? true))
            let remote = try reloaded.add(URL(string: "https://example.com/movie.mp4")!, title: "Network fixture")
            check("network-source-saved-without-opening", reloaded.film(remote.id)?.isNetwork == true)
            reloaded.remove(first.id)
            check("removing-record-keeps-source", FileManager.default.fileExists(atPath: nativeURL.path) && reloaded.film(first.id) == nil)
            let missingURL = folder.appending(path: "missing.mp4")
            try Data("temporary".utf8).write(to: missingURL)
            let missing = try reloaded.add(missingURL)
            try FileManager.default.removeItem(at: missingURL)
            do { _ = try reloaded.resolve(missing); check("missing-file-needs-relink", false) }
            catch { check("missing-file-needs-relink", true) }
            try reloaded.relocate(missing.id, to: nativeURL)
            check("relink-preserves-record", try reloaded.resolve(reloaded.film(missing.id)!).path == nativeURL.path)
            let cues = try SubtitleCue.parse(Data(contentsOf: .documentsDirectory.appending(path: "ProductCaptions.srt")))
            check("subtitle-timing-and-seek", SubtitleCue.text(at: 1, in: cues).contains("First caption") && SubtitleCue.text(at: 6, in: cues).contains("Second caption") && SubtitleCue.text(at: 12, in: cues).isEmpty)
            let vtt = Data("WEBVTT\n\n00:00.500 --> 00:02.000 align:center\n<b>Hello</b>\n".utf8)
            check("webvtt-parser", try SubtitleCue.parse(vtt).first?.text == "Hello")

            let native = try library.add(nativeURL, title: "Temporary native probe"); owned.append(native.id)
            openFilm(native)
            await waitForPendingChange(); await wait { duration > 0 && audioTracks.count >= 2 && !subtitleTracks.isEmpty }
            check("native-unified-player-and-tracks", showingPlayer && nativePresented == false && request?.engine == .native && audioTracks.count >= 2 && !subtitleTracks.isEmpty)
            if let last = audioTracks.last { selectAudio(last.id) }
            check("native-audio-selection", audioGroup.flatMap { nativePlayer?.currentItem?.currentMediaSelection.selectedMediaOption(in: $0) } == audioGroup?.options.last)
            if let first = subtitleTracks.first { selectSubtitle(first.id) }
            seek(to: 0.1)
            await wait(4) { subtitleText.contains("First caption") }
            check("native-embedded-caption-output", subtitleText.contains("First caption"))
            importSubtitle(.documentsDirectory.appending(path: "ProductCaptions.srt"))
            seek(to: 0.5)
            await wait(3) { subtitleText.contains("Second caption") }
            check("external-caption-after-seek", selectedSubtitle == "external" && subtitleText.contains("Second caption"))
            seek(to: 0.25); try? await Task.sleep(for: .milliseconds(400))
            if isPlaying { togglePlayback() }
            let paused = elapsed
            let chosenAudio = selectedAudio
            selectSubtitle("off")
            setCinema(true); await waitForPendingChange()
            await wait { duration > 0 && !audioTracks.isEmpty && selectedAudio == chosenAudio && !subtitleTracks.isEmpty && selectedSubtitle == "off" }
            check("cinema-restores-audio-and-disabled-subtitle", request?.isCinema == true && selectedSubtitle == "off" && !chosenAudio.isEmpty && selectedAudio == chosenAudio)
            let cinemaRequest = request?.id
            if let first = audioTracks.first { selectAudio(first.id) }
            selectSubtitle("external")
            let cinemaAudio = selectedAudio
            check("cinema-track-switch-keeps-session", request?.id == cinemaRequest && selectedSubtitle == "external" && !isPlaying && abs(elapsed - paused) < 0.6)
            setCinema(false); await waitForPendingChange()
            await wait { duration > 0 && selectedAudio == cinemaAudio && !audioTracks.isEmpty && abs(elapsed - paused) < 0.6 }
            check("cinema-tracks-return-to-window", request?.isCinema == false && selectedAudio == cinemaAudio && selectedSubtitle == "external" && !isPlaying)
            setLayout(.halfSBS); await waitForPendingChange()
            await wait { duration > 0 && abs(elapsed - paused) < 0.6 && renderedFrames > 0 }
            check("format-change-preserves-paused-position", request?.layout == .halfSBS && !isPlaying && abs(elapsed - paused) < 0.6 && renderedFrames > 0)
            setLayout(.flat); await waitForPendingChange()
            await wait { duration > 0 && abs(elapsed - paused) < 0.6 }
            depthStrength = 0.62; depthPopOut = 0.6; depthProportionProtection = false; savePicturePreferences()
            returnToLibrary(); await waitForPendingChange()
            let savedPosition = library.film(native.id)?.position ?? 0
            openFilm(library.film(native.id)!)
            await waitForPendingChange(); await wait { elapsed >= savedPosition - 0.4 && duration > 0 }
            check("return-and-resume", savedPosition > 2 && abs(elapsed - savedPosition) < 1 && depthStrength == 0.62 && depthPopOut == 0.6 && !depthProportionProtection)

            let other = try library.add(vlcURL, title: "Temporary VLC probe"); owned.append(other.id)
            openFilm(other); await waitForPendingChange(); await wait { duration > 0 && audioTracks.count >= 2 && !subtitleTracks.isEmpty }
            check("vlc-unified-player-and-tracks", request?.engine == .vlc && audioTracks.count >= 2 && !subtitleTracks.isEmpty && depthStrength == 0.35 && depthPopOut == 0 && depthProportionProtection && request?.converts2D == false)
            if let last = audioTracks.last { selectAudio(last.id) }
            await wait(3) { vlc?.audioTracks.last?["selected"] as? Bool == true }
            check("vlc-audio-selection", vlc?.audioTracks.last?["selected"] as? Bool == true)
            if let first = subtitleTracks.first { selectSubtitle(first.id) }
            await wait(3) { vlc?.subtitleTracks.first?["selected"] as? Bool == true }
            check("vlc-subtitle-selection", vlc?.subtitleTracks.first?["selected"] as? Bool == true)
            importSubtitle(.documentsDirectory.appending(path: "ProductCaptions.srt")); seek(to: 0.1)
            await wait(3) { subtitleText.contains("First caption") }
            check("vlc-external-caption", selectedSubtitle == "external" && subtitleText.contains("First caption"))
            pauseForBackground(); checkpoint()
            try? await Task.sleep(for: .milliseconds(500))
            check("background-pauses", !isPlaying)
        } catch { failure = error.localizedDescription }
        returnToLibrary(); await waitForPendingChange()
        for id in owned { library.remove(id) }
        try? FileManager.default.removeItem(at: folder)
        let report = smokeMetadata().merging([
            "sample": "product", "checks": checks, "error": failure ?? "",
            "passed": failure == nil && !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Persistent library, access recovery, per-film isolation, unified playback, native/VLC audio and subtitle selection, external text timing. Immersive comfort and UI usability require manual headset observation."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-product.json"), options: .atomic)
        }
    }
    #endif
}
