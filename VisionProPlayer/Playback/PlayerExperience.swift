import AVFoundation
import Foundation

extension PlayerModel {
    var currentFilm: LibraryFilm? { request?.libraryID.flatMap { library.film($0) } }
    var movieTitle: String { currentFilm?.title ?? request?.url.deletingPathExtension().lastPathComponent ?? "正在打开影片" }
    var pictureTitle: String {
        guard let request else { return "2D" }
        if request.isSpatialVideo { return "空间视频 · 原生 3D" }
        return request.layout.isStereo ? "原片 3D" : (request.converts2D ? "AI 立体" : "2D")
    }
    var hasEnded: Bool { duration > 0 && (elapsed >= duration - 0.3 || (stateText.contains("播放结束") && elapsed > duration * 0.9)) }

    func openFilm(_ film: LibraryFilm, fromStart: Bool = false) {
        checkpoint()
        do {
            let url = try library.resolve(film)
            missingFilmID = nil; errorMessage = nil
            library.update(film.id) { $0.lastOpened = Date() }
            let seconds = !fromStart && library.resumePlayback && film.resumable ? film.position : 0
            open(url, layout: film.preferences.layout, engine: .automatic, convert2D: film.preferences.converts2D,
                 recovery: (seconds, true), libraryID: film.id, cinema: cinemaActive)
            library.makeThumbnail(for: film)
        } catch {
            missingFilmID = film.id
            errorMessage = error.localizedDescription
        }
    }
    func importFilm(_ url: URL, title: String? = nil) {
        do { openFilm(try library.add(url, title: title)) }
        catch { errorMessage = error.localizedDescription }
    }
    func checkpoint() {
        guard let id = request?.libraryID, duration.isFinite, duration > 0, elapsed.isFinite else { return }
        let seconds = max(0, nativePlayer?.currentTime().seconds ?? elapsed)
        library.update(id) { $0.position = seconds.isFinite ? seconds : elapsed; $0.duration = duration }
    }
    func savePicturePreferences() {
        guard let request, let id = request.libraryID else { return }
        library.update(id) {
            $0.preferences.layout = request.layout
            $0.preferences.converts2D = request.converts2D
            $0.preferences.strength = depthStrength
            $0.preferences.swapped = swapEyes
            $0.preferences.subtitleOffset = subtitleOffset
        }
    }
    func reconfigure(layout: StereoLayout, conversion: Bool, cinema: Bool) {
        guard let current = request else { return }
        checkpoint()
        let seconds = nativePlayer?.currentTime().seconds ?? elapsed
        let playing = nativePlayer.map { $0.rate > 0 } ?? isPlaying
        eyeCheck = false
        open(current.url, layout: layout, engine: current.allowsNativeFallback ? .automatic : current.engine,
             convert2D: conversion, recovery: (seconds.isFinite ? seconds : 0, playing),
             libraryID: current.libraryID, cinema: cinema, resolvedEngine: current.engine)
    }
    func setLayout(_ layout: StereoLayout) {
        guard let current = request, current.layout != layout else { return }
        if let id = current.libraryID {
            library.update(id) { $0.preferences.layout = layout; if layout.isStereo { $0.preferences.converts2D = false } }
        }
        reconfigure(layout: layout, conversion: layout.isStereo ? false : current.converts2D, cinema: current.isCinema)
    }
    func setCinema(_ active: Bool) {
        cinemaActive = active
        guard let current = request, current.isCinema != active else { return }
        reconfigure(layout: current.layout, conversion: current.converts2D, cinema: active)
    }
    func returnToLibrary() {
        pauseForBackground(); checkpoint(); showingPlayer = false; stop()
    }
    func retryPlayback() {
        if let film = currentFilm { openFilm(film) }
        else if let current = request { reconfigure(layout: current.layout, conversion: current.converts2D, cinema: current.isCinema) }
    }
    func skip(_ seconds: Double) { if duration > 0 { seek(to: (elapsed + seconds) / duration) } }
    func restart() { seek(to: 0); if !isPlaying { togglePlayback() } }

    func loadTracks() {
        guard let request else { return }
        if let vlc {
            let audio = vlc.audioTracks, subs = vlc.subtitleTracks
            audioTracks = audio.compactMap { entry in
                guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
                return PlaybackTrack(id: id, title: title)
            }
            subtitleTracks = subs.compactMap { entry in
                guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
                return PlaybackTrack(id: id, title: title)
            }
            if let chosen = audio.first(where: { $0["selected"] as? Bool == true }) { selectedAudio = chosen["id"] as? String ?? "" }
            // Bitmap/burned-in subtitles across SBS are not safe to split. External
            // text subtitles are rendered once on the display plane for both eyes.
            if request.usesTextureOutput || selectedSubtitle == "external" { vlc.selectSubtitleTrack("") }
            else if let chosen = subs.first(where: { $0["selected"] as? Bool == true }) { selectedSubtitle = chosen["id"] as? String ?? "off" }
            return
        }
        guard trackTask == nil, let item = nativePlayer?.currentItem else { return }
        let requestID = request.id
        trackTask = Task { [weak self] in
            defer { if self?.request?.id == requestID { self?.trackTask = nil } }
            do {
                let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, let self, self.request?.id == requestID else { return }
                self.audioGroup = audio; self.subtitleGroup = subtitles
                self.audioTracks = audio?.options.enumerated().map { PlaybackTrack(id: String($0.offset), title: $0.element.displayName) } ?? []
                self.subtitleTracks = subtitles?.options.enumerated().map { PlaybackTrack(id: String($0.offset), title: $0.element.displayName) } ?? []
                if let audio, let chosen = item.currentMediaSelection.selectedMediaOption(in: audio), let index = audio.options.firstIndex(of: chosen) { self.selectedAudio = String(index) }
                if self.selectedSubtitle == "external", let subtitles { item.select(nil, in: subtitles) }
                else if let subtitles, let chosen = item.currentMediaSelection.selectedMediaOption(in: subtitles), let index = subtitles.options.firstIndex(of: chosen) { self.selectedSubtitle = String(index) }
            } catch { /* Media without selection groups can still play normally. */ }
        }
    }
    func selectAudio(_ id: String) {
        guard audioTracks.contains(where: { $0.id == id }) else { return }
        if let group = audioGroup, let index = Int(id), group.options.indices.contains(index) { nativePlayer?.currentItem?.select(group.options[index], in: group) }
        else { vlc?.selectAudioTrack(id) }
        selectedAudio = id
    }
    func selectSubtitle(_ id: String) {
        subtitleText = ""
        if id == "external" || id == "off" {
            if let group = subtitleGroup { nativePlayer?.currentItem?.select(nil, in: group) }
            vlc?.selectSubtitleTrack("")
        } else if let group = subtitleGroup, let index = Int(id), group.options.indices.contains(index) {
            nativePlayer?.currentItem?.select(group.options[index], in: group)
        } else if request?.usesTextureOutput == false { vlc?.selectSubtitleTrack(id) }
        else { return }
        selectedSubtitle = id
    }
    func importSubtitle(_ url: URL) {
        guard let id = request?.libraryID else { errorMessage = "请先从片库打开影片，再添加字幕。"; return }
        do { subtitleCues = try library.importSubtitle(url, for: id); selectSubtitle("external") }
        catch { errorMessage = error.localizedDescription }
    }
}
