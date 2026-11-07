import AVFoundation
import Foundation

extension PlayerModel {
    var currentDepthEffect: DepthEffect {
        DepthEffect(strength: depthStrength, popOut: depthPopOut,
                    proportionProtection: depthProportionProtection, preset: depthPreset)
    }

    func applyDepthEffect(_ effect: DepthEffect, persist: Bool = true) {
        let effect = effect.normalized
        depthStrength = effect.strength
        depthPopOut = effect.popOut
        depthProportionProtection = effect.proportionProtection
        depthPreset = effect.preset
        if persist { savePicturePreferences() }
    }

    func selectDepthPreset(_ preset: DepthPreset) {
        switch preset {
        case .natural: applyDepthEffect(.natural)
        case .foreground: applyDepthEffect(.foreground)
        case .custom:
            depthPreset = .custom
            savePicturePreferences()
        }
    }

    var captionAtTop: Bool { selectedSubtitle == "external" && library.externalCaptionAtTop }
    var currentFilm: LibraryFilm? { (request?.libraryID ?? openingFilmID).flatMap { library.film($0) } }
    var movieTitle: String { currentFilm?.title ?? request?.url.deletingPathExtension().lastPathComponent ?? "正在打开影片" }
    var pictureTitle: String {
        guard let request else { return "准备中" }
        if request.isSpatialVideo { return "空间视频 · 原生 3D" }
        return request.layout.isStereo ? "原片 3D" : (request.converts2D ? "AI · " + currentDepthEffect.preset.title : "普通 2D")
    }
    var loadingTitle: String? {
        if isSwitchingEngine { return "正在切换到 VLC 兼容播放…" }
        if isOpeningPhoto {
            return photoLoadingProgress != nil ? "正在从 iCloud 载入视频…" : "正在打开相册视频…"
        }
        let opening = stateText.contains("打开") || stateText == "准备播放"
        guard opening || stateText.contains("缓冲") else { return nil }
        if currentFilm?.isNetwork == true || ["smb", "http", "https"].contains(request?.url.scheme?.lowercased() ?? "") {
            return opening ? "正在连接影片来源…" : "正在缓冲网络影片…"
        }
        return stateText
    }
    var hasEnded: Bool { duration > 0 && (elapsed >= duration - 0.3 || (stateText.contains("播放结束") && elapsed > duration * 0.9)) }

    func openFilm(_ film: LibraryFilm, fromStart: Bool = false) {
        sourceRecovery = nil
        if library.pendingRemoval?.id == film.id { library.undoRemoval() }
        checkpoint()
        let film = library.film(film.id) ?? film
        do {
            let url: URL
            if let serverID = film.networkServerID {
                guard let path = film.networkPath else { throw NetworkSourceError.invalidAddress }
                url = try networkServers.source(serverID: serverID, path: path).url
            } else if film.photoAssetIdentifier != nil {
                url = URL(string: "photos://reference/" + film.id.uuidString)!
            } else { url = try library.resolve(film) }
            missingFilmID = nil; errorMessage = nil
            library.update(film.id) { $0.lastOpened = Date() }
            let seconds = !fromStart && library.resumePlayback && film.resumable ? film.position : 0
            open(url, layout: film.preferences.layout, engine: .automatic, convert2D: film.preferences.converts2D,
                 recovery: (seconds, true), libraryID: film.id, cinema: cinemaActive)
            library.makeThumbnail(for: film)
        } catch {
            if film.networkServerID != nil { sourceRecovery = .server }
            if film.photoFile != nil { sourceRecovery = .choosePhoto }
            missingFilmID = film.sourceFilter == .files ? film.id : nil
            errorMessage = error.localizedDescription
        }
    }
    func importFilm(_ url: URL, title: String? = nil) {
        do { openFilm(try library.add(url, title: title)) }
        catch { errorMessage = error.localizedDescription }
    }
    func checkpoint() {
        guard let id = request?.libraryID, duration.isFinite, duration > 0, elapsed.isFinite else { return }
        let seconds = max(0, request?.url.scheme?.lowercased() == "smb" && vlc?.failed == true
                          ? lastNetworkPosition : (nativePlayer?.currentTime().seconds ?? elapsed))
        library.updateProgress(id, seconds: seconds.isFinite ? seconds : elapsed, duration: duration)
    }
    func savePicturePreferences() {
        guard let request, let id = request.libraryID else { return }
        library.update(id) {
            $0.preferences.layout = request.layout
            $0.preferences.converts2D = request.converts2D
            $0.preferences.depthEffect = currentDepthEffect
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
             libraryID: current.libraryID, cinema: cinema, resolvedEngine: current.engine, restoringTracks: preferredTracks, photoAssetIdentifier: current.photoAssetIdentifier, networkCredentials: current.networkCredentials)
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

    func switchEngine(_ engine: PlaybackEngine) {
        guard let current = request, engine != current.engine, engine != .automatic,
              !current.isSpatialVideo else { return }
        guard current.url.scheme?.lowercased() != "smb" else { playbackNotice = "SMB 共享使用 VLC 兼容播放。"; return }
        guard current.photoAssetIdentifier == nil else { playbackNotice = PhotoPlaybackSource.AccessError.nativeOnly.localizedDescription; return }
        checkpoint()
        let seconds = nativePlayer?.currentTime().seconds ?? elapsed
        open(current.url, layout: current.layout, engine: engine, convert2D: current.converts2D,
             recovery: (seconds.isFinite ? seconds : 0, isPlaying), libraryID: current.libraryID,
             cinema: current.isCinema, restoringTracks: preferredTracks)
    }

    func loadTracks() {
        guard let request else { return }
        if let vlc {
            let audio = vlc.audioTracks, subs = vlc.subtitleTracks
            func tracks(_ entries: [[String: Any]]) -> [PlaybackTrack] {
                entries.compactMap { entry in
                    guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
                    return PlaybackTrack(id: id, title: title, language: entry["language"] as? String)
                }
            }
            audioTracks = tracks(audio); subtitleTracks = tracks(subs)
            selectedAudio = audio.first(where: { $0["selected"] as? Bool == true })?["id"] as? String ?? ""
            let embedded = subs.first(where: { $0["selected"] as? Bool == true })?["id"] as? String
            let externalActive = preferredTracks.subtitle?.mode == .external && !subtitleCues.isEmpty
            selectedSubtitle = embedded ?? (externalActive ? "external" : "off")
            if request.usesTextureOutput {
                // Keep the preference, but do not burn one embedded caption into
                // both packed eyes. Returning to a supported path restores it.
                if embedded != nil { vlc.selectSubtitleTrack("") }
                selectedSubtitle = externalActive ? "external" : "off"
            }
            restoreTrackChoices()
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
                func tracks(_ group: AVMediaSelectionGroup?) -> [PlaybackTrack] {
                    group?.options.enumerated().map {
                        PlaybackTrack(id: String($0.offset), title: $0.element.displayName,
                                      language: $0.element.extendedLanguageTag ?? $0.element.locale?.identifier,
                                      isForcedOnly: $0.element.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
                    } ?? []
                }
                self.audioTracks = tracks(audio); self.subtitleTracks = tracks(subtitles)
                if let audio, let chosen = item.currentMediaSelection.selectedMediaOption(in: audio), let index = audio.options.firstIndex(of: chosen) { self.selectedAudio = String(index) }
                if let subtitles, let chosen = item.currentMediaSelection.selectedMediaOption(in: subtitles), let index = subtitles.options.firstIndex(of: chosen) { self.selectedSubtitle = String(index) }
                else { self.selectedSubtitle = "off" }
                self.restoreTrackChoices()
            } catch { /* Media without selection groups can still play normally. */ }
        }
    }

    private func saveTrackChoices() {
        guard let id = request?.libraryID else { return }
        let choices = preferredTracks
        library.update(id) { $0.preferences.trackChoices = choices }
    }

    private func restoreTrackChoices() {
        guard let request else { return }
        var notices: [String] = []
        if let audio = preferredTracks.audio {
            if let track = audio.resolve(in: audioTracks, engine: request.engine.rawValue) {
                if selectedAudio != track.id { applyAudio(track.id) }
            } else if !audioTracks.isEmpty {
                notices.append("暂未找到原先选择的音轨，正在使用可用音轨；原选择已保留。")
            }
        }
        if let subtitle = preferredTracks.subtitle {
            switch subtitle.mode {
            case .off: applySubtitle("off")
            case .external:
                if !subtitleCues.isEmpty { applySubtitle("external") }
                else {
                    applySubtitle("off")
                    notices.append("原先选择的外挂字幕无法读取，请重新导入；原选择已保留。")
                }
            case .embedded:
                if request.engine == .vlc && request.usesTextureOutput {
                    applySubtitle("off")
                    notices.append("已记住内嵌字幕选择；当前 VLC 立体或影院模式暂不显示，返回支持的播放模式后恢复。")
                } else if let track = subtitle.track?.resolve(in: subtitleTracks, engine: request.engine.rawValue) {
                    if selectedSubtitle != track.id { applySubtitle(track.id) }
                } else {
                    applySubtitle("off")
                    notices.append("暂未找到原先选择的内嵌字幕；原选择已保留。")
                }
            }
        }
        trackPreferenceNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
    }

    private func applyAudio(_ id: String) {
        if let group = audioGroup, let index = Int(id), group.options.indices.contains(index) {
            nativePlayer?.appliesMediaSelectionCriteriaAutomatically = false
            nativePlayer?.currentItem?.select(group.options[index], in: group)
        } else { vlc?.selectAudioTrack(id) }
        selectedAudio = id
    }

    private func applySubtitle(_ id: String) {
        if id != selectedSubtitle { subtitleText = "" }
        if let group = subtitleGroup, let player = nativePlayer {
            player.appliesMediaSelectionCriteriaAutomatically = false
            let option = Int(id).flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
            if player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) != option {
                player.currentItem?.select(option, in: group)
            }
        } else if let vlc, selectedSubtitle != id {
            // loadTracks reflects actual selection before restoring; no periodic
            // deselect calls when subtitles are already disabled.
            if id == "off" || id == "external" {
                if selectedSubtitle != "off" && selectedSubtitle != "external" { vlc.selectSubtitleTrack("") }
            } else { vlc.selectSubtitleTrack(id) }
        }
        selectedSubtitle = id
        if id == "off" { subtitleText = "" }
    }

    func selectAudio(_ id: String) {
        guard let request, let track = audioTracks.first(where: { $0.id == id }) else { return }
        preferredTracks.audio = SavedPlaybackTrack(track, engine: request.engine.rawValue)
        applyAudio(id); saveTrackChoices(); restoreTrackChoices()
    }

    func selectSubtitle(_ id: String) {
        guard let request else { return }
        if id == "off" { preferredTracks.subtitle = SavedSubtitleChoice(mode: .off) }
        else if id == "external", !subtitleCues.isEmpty { preferredTracks.subtitle = SavedSubtitleChoice(mode: .external) }
        else if !(request.engine == .vlc && request.usesTextureOutput),
                let track = subtitleTracks.first(where: { $0.id == id }) {
            preferredTracks.subtitle = SavedSubtitleChoice(mode: .embedded, track: SavedPlaybackTrack(track, engine: request.engine.rawValue))
        } else { return }
        applySubtitle(id); saveTrackChoices(); restoreTrackChoices()
    }

    func importSubtitle(_ url: URL) {
        guard let id = request?.libraryID else { errorMessage = "请先从片库打开影片，再添加字幕。"; return }
        do { subtitleCues = try library.importSubtitle(url, for: id); selectSubtitle("external") }
        catch { errorMessage = error.localizedDescription }
    }
}
