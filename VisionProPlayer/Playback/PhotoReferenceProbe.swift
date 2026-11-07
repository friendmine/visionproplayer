import AVFoundation
import Photos

#if DEBUG
extension PlayerModel {
    func runPhotoReferenceProbe() async {
        var checks: [[String: Any]] = []
        var tested: [String] = []
        var failure = ""
        let folder = URL.temporaryDirectory.appending(path: "photo-reference-probe-\(UUID().uuidString)")
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func wait(_ predicate: () -> Bool) async {
            for _ in 0..<120 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func copyBytes() -> Int {
            let root = URL.applicationSupportDirectory.appending(path: "MediaLibrary/PhotoVideos")
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        do {
            let store = MediaLibrary(root: folder)
            let legacy = try JSONDecoder().decode(LibraryFilm.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","location":"file:///example.mov","photoFile":"old.mov","favorite":false,"addedAt":0,"position":5,"duration":12,"preferences":{"layout":"flat","converts2D":false,"strength":0.35,"swapped":false,"subtitleOffset":0}}"#.utf8))
            check("legacy-offline-copy-decodes", legacy.photoAssetIdentifier == nil && legacy.photoFile == "old.mov")
            let film = try store.addPhotoReference(identifier: "synthetic-reference", title: "Reference probe", duration: 12, spatial: false)
            check("reference-not-network-and-no-owned-copy", !film.isNetwork && film.photoFile == nil && film.bookmark == nil)
            store.update(film.id) {
                $0.position = 4; $0.lastOpened = Date(); $0.favorite = true
                $0.preferences.trackChoices = PlaybackTrackChoices(subtitle: SavedSubtitleChoice(mode: .off))
                $0.preferences.depthEffect = .foreground
            }
            let again = try store.addPhotoReference(identifier: "synthetic-reference", title: "Ignored replacement", duration: 15, spatial: true)
            check("same-asset-deduplicates-and-keeps-preferences", again.id == film.id && again.position == 4 && again.favorite && again.preferences.trackChoices?.subtitle?.mode == .off)
            let disk = MediaLibrary(root: folder)
            check("reference-progress-and-preferences-persist", disk.film(film.id) == store.film(film.id))
            check("reference-does-not-create-video-directory", !FileManager.default.fileExists(atPath: folder.appending(path: "PhotoVideos").path))
            do { _ = try store.resolve(film); check("reference-rejects-file-resolution", false) }
            catch { check("reference-rejects-file-resolution", true) }
            try store.clearWatchHistory()
            check("clear-history-retains-reference-and-preferences", store.film(film.id)?.photoAssetIdentifier == "synthetic-reference" && store.film(film.id)?.position == 0 && store.film(film.id)?.preferences.trackChoices?.subtitle?.mode == .off)
            store.remove(film.id)
            check("remove-reference-only-removes-record", store.films.isEmpty && MediaLibrary(root: folder).films.isEmpty)

            // Read only references the user explicitly added. Run transient
            // playback sessions without libraryID so their progress/preferences
            // are not overwritten. No asset identifiers or imagery in reports.
            let references = library.recent.filter { $0.photoAssetIdentifier != nil }
            var samples: [LibraryFilm] = []
            if let flat = references.first(where: { $0.isSpatialVideo != true }) { samples.append(flat) }
            if let spatial = references.first(where: { $0.isSpatialVideo == true }) { samples.append(spatial) }
            let before = copyBytes()
            for film in samples {
                let kind = film.isSpatialVideo == true ? "spatial" : "flat"
                tested.append(kind)
                let saved = library.film(film.id)
                let marker = URL(string: "photos://reference/probe")!
                open(marker, layout: .flat, engine: .automatic, convert2D: false,
                     photoAssetIdentifier: film.photoAssetIdentifier)
                await waitForPendingChange()
                await wait { elapsed > 0.5 || errorMessage != nil }
                check("\(kind)-photokit-native-playback", request?.photoAssetIdentifier != nil && request?.engine == .native && nativePlayer?.currentItem != nil && elapsed > 0.5 && errorMessage == nil && vlc == nil)
                check("\(kind)-spatial-routing", request?.isSpatialVideo == (kind == "spatial") && (kind != "spatial" || request?.usesTextureOutput == false))
                if let request, duration > 0 {
                    let reader = SeekFrameReader(request, asset: nativePlayer?.currentItem?.asset)
                    let preview = await reader.frame(at: min(1, duration / 2), swapped: false)
                    check("\(kind)-preview-uses-photokit-asset", preview != nil)
                } else { check("\(kind)-preview-uses-photokit-asset", false) }
                seek(to: min(0.4, 2 / max(1, duration)))
                await wait { elapsed > 1 }
                if isPlaying { togglePlayback() }
                await wait { !isPlaying }
                let position = elapsed
                let target = min(position, max(0, duration - 0.2))
                setCinema(true); await waitForPendingChange()
                await wait { duration > 0 && abs(elapsed-target) < 0.8 }
                check("\(kind)-cinema-reacquires-reference", request?.isCinema == true && request?.photoAssetIdentifier == film.photoAssetIdentifier && !isPlaying && abs(elapsed-target) < 0.8)
                setCinema(false); await waitForPendingChange()
                await wait { duration > 0 && abs(elapsed-target) < 0.8 }
                check("\(kind)-window-retains-paused-position", request?.isCinema == false && !isPlaying && abs(elapsed-target) < 0.8)
                if kind == "flat" {
                    setDepthConversion(true); await waitForPendingChange()
                    if !isPlaying { togglePlayback() }
                    await wait { depthConvertedFrames > 5 || errorMessage != nil }
                    check("flat-ai-reuses-native-photo-source", request?.converts2D == true && request?.photoAssetIdentifier != nil && depthConvertedFrames > 5 && rendererError == nil)
                }
                returnToLibrary(); await waitForPendingChange()
                check("\(kind)-user-record-unchanged", library.film(film.id) == saved)
            }
            check("no-app-owned-movie-copy-added", copyBytes() == before)
            open(URL(string: "photos://reference/missing")!, layout: .flat, engine: .automatic,
                 photoAssetIdentifier: "deliberately-missing-photo-reference")
            await waitForPendingChange()
            check("missing-or-denied-reference-fails-without-vlc", request == nil && vlc == nil && errorMessage != nil && !isOpeningPhoto)
            returnToLibrary(); await waitForPendingChange(); errorMessage = nil
            open(URL(string: "photos://reference/cancelled")!, layout: .flat, engine: .automatic,
                 photoAssetIdentifier: "deliberately-missing-photo-reference")
            stop(); showingPlayer = false
            await waitForPendingChange()
            check("cancelled-queued-open-does-not-reappear", request == nil && !isOpeningPhoto && !showingPlayer)
        } catch { failure = "Probe operation failed: \(type(of: error))" }
        returnToLibrary(); await waitForPendingChange()
        try? FileManager.default.removeItem(at: folder)
        let report = smokeMetadata().merging([
            "sample": "photo-reference", "checks": checks, "testedMediaKinds": tested, "error": failure,
            "passed": failure.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Reference persistence and no-copy accounting; only user-added Photos references are played. Empty testedMediaKinds means no actual Photos playback was tested. Permission UI, iCloud-only media, visible stereo and audible playback require wearer confirmation. No asset IDs, filenames or content recorded."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-photo-reference.json"), options: .atomic)
        }
    }
}
#endif
