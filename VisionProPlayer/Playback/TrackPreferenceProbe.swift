import AVFoundation
import Foundation

#if DEBUG
extension PlayerModel {
    func runTrackPreferenceProbe() async {
        var checks: [[String: Any]] = []
        var owned: [UUID] = []
        var failure: String?
        var expectedPausedPosition = 0.0
        let folder = URL.temporaryDirectory.appending(path: "track-preferences-\(UUID().uuidString)")
        func check(_ name: String, _ passed: Bool) {
            var result: [String: Any] = ["name": name, "passed": passed]
            if !passed {
                result["state"] = ["audioRestored": audioRestored(), "embeddedRestored": embeddedRestored(),
                                   "subtitleDisabledInEngine": actualSubtitle() == nil,
                                   "subtitleMode": preferredTracks.subtitle?.mode.rawValue ?? "default",
                                   "selectedSubtitleKind": selectedSubtitle == "off" || selectedSubtitle == "external" ? selectedSubtitle : "embedded",
                                   "playing": isPlaying, "elapsed": elapsed, "expectedPausedPosition": expectedPausedPosition, "cinema": request?.isCinema ?? false]
            }
            checks.append(result)
        }
        func wait(_ predicate: () -> Bool) async {
            for _ in 0..<100 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        func ready() async {
            await waitForPendingChange()
            await wait { duration > 0 && audioTracks.count == 2 && !subtitleTracks.isEmpty }
            // Track selection is asynchronous in both decoders. Wait for the
            // real engine selection, not merely the published options list.
            await wait {
                guard let request else { return false }
                if let target = preferredTracks.audio?.resolve(in: audioTracks, engine: request.engine.rawValue), actualAudio() != target.id { return false }
                switch preferredTracks.subtitle?.mode {
                case .off, .external: return actualSubtitle() == nil
                case .embedded:
                    if request.engine == .vlc && request.usesTextureOutput { return actualSubtitle() == nil }
                    if let target = preferredTracks.subtitle?.track?.resolve(in: subtitleTracks, engine: request.engine.rawValue) { return actualSubtitle() == target.id }
                    return true
                case nil: return true
                }
            }
        }
        func actualAudio() -> String? {
            if let group = audioGroup, let item = nativePlayer?.currentItem,
               let selected = item.currentMediaSelection.selectedMediaOption(in: group), let i = group.options.firstIndex(of: selected) { return String(i) }
            return vlc?.audioTracks.first(where: { $0["selected"] as? Bool == true })?["id"] as? String
        }
        func actualSubtitle() -> String? {
            if let group = subtitleGroup, let item = nativePlayer?.currentItem,
               let selected = item.currentMediaSelection.selectedMediaOption(in: group), let i = group.options.firstIndex(of: selected) { return String(i) }
            return vlc?.subtitleTracks.first(where: { $0["selected"] as? Bool == true })?["id"] as? String
        }
        func audioRestored() -> Bool {
            guard let request, let track = preferredTracks.audio?.resolve(in: audioTracks, engine: request.engine.rawValue) else { return false }
            return actualAudio() == track.id
        }
        func embeddedRestored() -> Bool {
            guard let request, let track = preferredTracks.subtitle?.track?.resolve(in: subtitleTracks, engine: request.engine.rawValue) else { return false }
            return actualSubtitle() == track.id
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let legacy = try JSONDecoder().decode(FilmPreferences.self, from: Data(#"{"layout":"flat","converts2D":false,"strength":0.35,"swapped":false,"subtitleOffset":0}"#.utf8))
            check("legacy-preferences-without-track-fields-decode", legacy.trackChoices == nil)
            for (ext, engine) in [("mp4", PlaybackEngine.native), ("mkv", .vlc)] {
                let url = folder.appending(path: "tracks.\(ext)")
                try FileManager.default.copyItem(at: .documentsDirectory.appending(path: "ProductTracks.\(ext)"), to: url)
                let film = try library.add(url, title: "Temporary track preference probe")
                owned.append(film.id)
                openFilm(film, fromStart: true); await ready()
                check("\(ext)-tracks-ready", request?.engine == engine && audioTracks.count == 2 && !subtitleTracks.isEmpty)
                guard let audio = audioTracks.last, let subtitle = subtitleTracks.first else { throw MediaLibrary.LibraryError.unavailable }
                selectAudio(audio.id); selectSubtitle(subtitle.id)
                await wait { audioRestored() && embeddedRestored() }
                check("\(ext)-explicit-selection-applied-to-engine", audioRestored() && embeddedRestored())
                let desired = preferredTracks
                let reloaded = MediaLibrary()
                check("\(ext)-choices-written-to-disk", reloaded.film(film.id)?.preferences.trackChoices == desired)
                returnToLibrary(); await waitForPendingChange()
                openFilm(reloaded.film(film.id)!, fromStart: true); await ready()
                await wait { audioRestored() && embeddedRestored() }
                check("\(ext)-reopen-restores-engine-tracks", preferredTracks == desired && audioRestored() && embeddedRestored())

                if ext == "mp4" {
                    switchEngine(.vlc); await ready()
                    await wait { audioRestored() && embeddedRestored() }
                    check("native-to-vlc-semantic-track-match", request?.engine == .vlc && audioRestored() && embeddedRestored() && preferredTracks == desired)
                    // Save a VLC-origin descriptor too; native exposes an extra
                    // forced-only option for the same language in this fixture.
                    if let sub = subtitleTracks.first { selectSubtitle(sub.id) }
                    let vlcDesired = preferredTracks
                    switchEngine(.native); await ready()
                    await wait { audioRestored() && embeddedRestored() }
                    check("vlc-to-native-semantic-track-match", request?.engine == .native && audioRestored() && embeddedRestored() && preferredTracks == vlcDesired)
                    selectAudio(audio.id); selectSubtitle(subtitle.id)
                }
                if isPlaying { togglePlayback() }
                await wait { !isPlaying }
                try? await Task.sleep(for: .milliseconds(250))
                let pausedPosition = elapsed
                expectedPausedPosition = pausedPosition
                setCinema(true); await ready()
                await wait { audioRestored() && (engine == .vlc ? actualSubtitle() == nil : embeddedRestored()) }
                await wait { !isPlaying && abs(elapsed-pausedPosition) < 0.8 }
                check("\(ext)-cinema-retains-track-intent", preferredTracks == desired && audioRestored()
                      && (engine == .vlc ? actualSubtitle() == nil && trackPreferenceNotice != nil : embeddedRestored()))
                setCinema(false); await ready()
                await wait { audioRestored() && embeddedRestored() }
                await wait { !isPlaying && abs(elapsed-pausedPosition) < 0.8 }
                check("\(ext)-window-restores-embedded-subtitle", embeddedRestored() && audioRestored())
                check("\(ext)-paused-position-survives-cinema-return", !isPlaying && abs(elapsed-pausedPosition) < 0.8)

                importSubtitle(.documentsDirectory.appending(path: "ProductCaptions.srt"))
                seek(to: 0.1)
                await wait { selectedSubtitle == "external" && actualSubtitle() == nil && !subtitleText.isEmpty }
                check("\(ext)-external-disables-embedded", selectedSubtitle == "external" && actualSubtitle() == nil && !subtitleText.isEmpty)
                returnToLibrary(); await waitForPendingChange()
                openFilm(library.film(film.id)!, fromStart: true); await ready()
                await wait { selectedSubtitle == "external" && actualSubtitle() == nil }
                check("\(ext)-external-survives-reopen", selectedSubtitle == "external" && actualSubtitle() == nil && audioRestored())
                selectSubtitle("off")
                await wait { actualSubtitle() == nil && subtitleText.isEmpty }
                let off = preferredTracks
                check("\(ext)-off-written-to-disk", MediaLibrary().film(film.id)?.preferences.trackChoices == off && off.subtitle?.mode == .off)
                returnToLibrary(); await waitForPendingChange()
                openFilm(library.film(film.id)!, fromStart: true); await ready()
                try? await Task.sleep(for: .milliseconds(600))
                check("\(ext)-off-overrides-imported-subtitle-file", !subtitleCues.isEmpty && selectedSubtitle == "off" && actualSubtitle() == nil && subtitleText.isEmpty && audioRestored())
                if ext == "mp4" {
                    switchEngine(.vlc); await ready()
                    await wait { selectedSubtitle == "off" && actualSubtitle() == nil && audioRestored() }
                    check("off-and-audio-survive-engine-switch", selectedSubtitle == "off" && actualSubtitle() == nil && subtitleText.isEmpty && audioRestored())
                }
                if isPlaying { togglePlayback() }
                setCinema(true); await ready()
                check("\(ext)-off-survives-cinema", selectedSubtitle == "off" && actualSubtitle() == nil && preferredTracks == off)
                setCinema(false); await ready()
                check("\(ext)-off-survives-window-return", selectedSubtitle == "off" && actualSubtitle() == nil && subtitleText.isEmpty && audioRestored())

                selectSubtitle("external")
                setCinema(true); await ready()
                check("\(ext)-external-survives-cinema", selectedSubtitle == "external" && actualSubtitle() == nil && audioRestored())
                setCinema(false); await ready()
                check("\(ext)-external-survives-window-return", selectedSubtitle == "external" && actualSubtitle() == nil)
                let beforeDiagnostic = library.film(film.id)?.preferences
                openSample(url, layout: .flat, engine: engine); await ready()
                if let first = audioTracks.first { selectAudio(first.id) }
                selectSubtitle("off")
                check("\(ext)-diagnostic-does-not-overwrite-film", library.film(film.id)?.preferences == beforeDiagnostic)
                returnToLibrary(); await waitForPendingChange()
            }
            // A missing imported file must not erase intent, while a legacy
            // record with an existing external file preserves its old behavior.
            guard let id = owned.first else { throw MediaLibrary.LibraryError.unavailable }
            library.update(id) { $0.preferences.trackChoices = PlaybackTrackChoices(subtitle: SavedSubtitleChoice(mode: .off)) }
            openFilm(library.film(id)!, fromStart: true); await ready()
            check("subtitle-only-preference-preserves-default-audio", actualAudio() != nil && actualSubtitle() == nil)
            returnToLibrary(); await waitForPendingChange()
            library.update(id) { $0.preferences.trackChoices = nil }
            openFilm(library.film(id)!, fromStart: true); await ready()
            check("legacy-external-subtitle-keeps-existing-behavior", selectedSubtitle == "external")
            selectSubtitle("external")
            if let file = currentFilm?.preferences.subtitleFile { try FileManager.default.removeItem(at: library.subtitleURL(file)) }
            returnToLibrary(); await waitForPendingChange()
            openFilm(library.film(id)!, fromStart: true); await ready()
            check("missing-external-keeps-preference-and-shows-notice", selectedSubtitle == "off" && preferredTracks.subtitle?.mode == .external && trackPreferenceNotice != nil)
        } catch { failure = "Fixture or probe operation failed: \(type(of: error))" }
        returnToLibrary(); await waitForPendingChange()
        for id in owned { library.remove(id) }
        try? FileManager.default.removeItem(at: folder)
        let report = smokeMetadata().merging([
            "sample": "track-preferences", "checks": checks, "error": failure ?? "",
            "passed": failure == nil && !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Disk reload and actual native/VLC selection; same-film engine changes; cinema session changes; external/off/missing subtitles; legacy records and diagnostic isolation. Physical UI interaction and audible track identity require wearer confirmation."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-track-preferences.json"), options: .atomic)
        }
    }
}
#endif
