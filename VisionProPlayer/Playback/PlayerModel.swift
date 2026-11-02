import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class PlayerModel {
    let library = MediaLibrary()
    let focus = FocusPlayback()
    var showingPlayer = false
    var missingFilmID: UUID?
    var cinemaActive = false
    var cinemaTransition = false
    var spatialStereoActive = false
    var audioTracks: [PlaybackTrack] = []
    var subtitleTracks: [PlaybackTrack] = []
    var selectedAudio = ""
    var selectedSubtitle = "off"
    var subtitleText = ""
    var subtitleCues: [SubtitleCue] = []
    var subtitleOffset = 0.0
    @ObservationIgnored var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored var subtitleGroup: AVMediaSelectionGroup?
    @ObservationIgnored var captionReceiver: CaptionReceiver?
    @ObservationIgnored var trackTask: Task<Void, Never>?
    @ObservationIgnored var lastCheckpoint = 0.0
    @ObservationIgnored var lastTrackRefresh = 0.0
    var engineChoice: PlaybackEngine = .automatic
    var layoutChoice: StereoLayout = .flat
    var swapEyes = false
    var eyeCheck = false
    var depthEnabled = false
    var depthStrength: Float = 0.35
    var depthPopOut: Float = 0
    var depthProportionProtection = true
    @ObservationIgnored var depthScreenWidthMeters: Float = 0
    var depthRevision = 0
    var depthStatus = "等待转换"
    var depthInferenceMS = 0.0
    var depthDisplayFPS = 0.0
    var depthPredictions = 0
    var depthConvertedFrames = 0
    var depthInferenceSamples: [Double] = []
    var depthAgeSamples: [Double] = []
    @ObservationIgnored var depthGainSamples: [Float] = []
    @ObservationIgnored var depthSceneResets = 0
    @ObservationIgnored let depthEstimator = DepthEstimator()
    @ObservationIgnored private var depthFrameTimes: [Double] = []
    var request: PlaybackRequest?
    var nativePlayer: AVPlayer?
    var vlc: VPPVLCSession?
    var stateText = "选择一个测试片或导入自己的视频"
    var errorMessage: String?
    var progress = 0.0
    var elapsed = 0.0
    var duration = 0.0
    var isPlaying = false
    var isSeekable = false
    var nativePresented = false
    var isClosing = false
    var renderedFrames = 0
    var stereoDisplayAspect = 0.0
    var frameSize = "等待视频帧"
    var rendererError: String?
    var playbackNotice: String?
    private(set) var isSwitchingEngine = false
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var nativeStatus: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOpen: Task<Void, Never>?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var wantsPlayback = true
    @ObservationIgnored private var pendingVLCRecovery: (seconds: Double, playing: Bool)?

    /// Test presets never change the choices used for the user's next file.
    func openSample(_ url: URL, layout: StereoLayout, engine: PlaybackEngine, convert2D: Bool = false) {
        depthProportionProtection = true
        eyeCheck = false
        swapEyes = false
        open(url, layout: layout, engine: engine, convert2D: convert2D)
    }

    func setDepthConversion(_ enabled: Bool) {
        depthEnabled = enabled
        guard let current = request, !current.isSpatialVideo, !current.layout.isStereo, current.converts2D != enabled else { return }
        if let id = current.libraryID { library.update(id) { $0.preferences.converts2D = enabled } }
        reconfigure(layout: current.layout, conversion: enabled, cinema: current.isCinema)
    }

    func recordDepthPrediction(milliseconds: Double) {
        depthPredictions += 1
        depthInferenceMS = milliseconds
        depthInferenceSamples.append(milliseconds)
        if depthInferenceSamples.count > 600 { depthInferenceSamples.removeFirst() }
    }

    func recordConvertedFrame(age: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        depthConvertedFrames += 1
        depthFrameTimes.append(now)
        depthFrameTimes.removeAll { now - $0 > 1 }
        depthDisplayFPS = Double(max(0, depthFrameTimes.count - 1)) / max(0.001, now - (depthFrameTimes.first ?? now))
        depthAgeSamples.append(age)
        if depthAgeSamples.count > 600 { depthAgeSamples.removeFirst() }
        depthStatus = "2D 转 3D · 实验性"
    }

    func open(_ url: URL, layout: StereoLayout? = nil, engine: PlaybackEngine? = nil, convert2D: Bool? = nil,
              recovery: (seconds: Double, playing: Bool)? = nil, libraryID: UUID? = nil,
              cinema: Bool = false, resolvedEngine: PlaybackEngine? = nil) {
        showingPlayer = true
        // Take access before the fileImporter callback returns; release only after decoder shutdown.
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        let selectedLayout = layout ?? layoutChoice
        let preference = engine ?? engineChoice
        let selectedEngine = resolvedEngine ?? preference.resolved(for: url)
        let conversion = (convert2D ?? depthEnabled) && !selectedLayout.isStereo
        openGeneration += 1
        let generation = openGeneration
        let previous = pendingOpen
        pendingOpen = Task { [weak self] in
            await previous?.value
            guard let self else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            guard generation == self.openGeneration else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            await self.shutdown()
            guard generation == self.openGeneration else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            var spatial = false
            if selectedLayout == .flat, selectedEngine == .native, url.isFileURL {
                let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
                spatial = tracks?.isEmpty == false
            }
            guard generation == self.openGeneration else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            if let libraryID { self.library.update(libraryID) { $0.isSpatialVideo = spatial } }
            self.start(PlaybackRequest(url: url, engine: selectedEngine, layout: selectedLayout,
                                       swapEyes: self.swapEyes, securityScoped: scoped,
                                       allowsNativeFallback: preference == .automatic && !spatial,
                                       converts2D: conversion && !spatial, libraryID: libraryID, isCinema: cinema, isSpatialVideo: spatial), recovery: recovery)
        }
    }

    private func start(_ next: PlaybackRequest, recovery: (seconds: Double, playing: Bool)? = nil,
                       notice: String? = nil) {
        request = next
        spatialStereoActive = false
        if let id = next.libraryID, let film = library.film(id) {
            swapEyes = film.preferences.swapped
            depthStrength = film.preferences.strength
            depthPopOut = min(1, max(0, film.preferences.popOut ?? 0))
            depthProportionProtection = film.preferences.proportionProtection ?? true
            subtitleOffset = film.preferences.subtitleOffset
            if let file = film.preferences.subtitleFile,
               let data = try? Data(contentsOf: library.subtitleURL(file)), let cues = try? SubtitleCue.parse(data) {
                subtitleCues = cues; selectedSubtitle = "external"
            }
        }
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
        isSwitchingEngine = false
        playbackNotice = notice
        wantsPlayback = recovery?.playing ?? true
        pendingVLCRecovery = recovery
        depthRevision += 1
        depthStatus = next.converts2D ? "正在准备深度模型…" : "等待转换"
        depthPredictions = 0; depthConvertedFrames = 0; depthFrameTimes = []; depthInferenceMS = 0; depthDisplayFPS = 0
        depthInferenceSamples.removeAll(); depthAgeSamples.removeAll(); depthGainSamples.removeAll()
        depthSceneResets = 0
        errorMessage = nil; rendererError = nil
        renderedFrames = 0; stereoDisplayAspect = 0; frameSize = "等待视频帧"
        progress = 0; elapsed = 0; duration = 0
        isPlaying = false; isSeekable = false
        stateText = "正在打开"
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            if next.engine == .native {
                let item = AVPlayerItem(url: next.url)
                if next.usesTextureOutput {
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferMetalCompatibilityKey as String: true
                    ])
                    item.add(output)
                    videoOutput = output
                }
                let captions = AVPlayerItemLegibleOutput()
                captions.suppressesPlayerRendering = true
                let receiver = CaptionReceiver()
                receiver.receive = { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.request?.id == next.id, self.selectedSubtitle != "external" else { return }
                        self.subtitleText = text
                    }
                }
                captions.setDelegate(receiver, queue: .main)
                item.add(captions); captionReceiver = receiver
                let player = AVPlayer(playerItem: item)
                nativePlayer = player
                nativeStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    let ready = item.status == .readyToPlay
                    let message = item.error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.request?.id == next.id else { return }
                        if ready { self.loadTracks() }
                        if failed {
                            self.nativeFailed(requestID: next.id, message: message ?? "原生播放器无法打开此文件。")
                        } else if ready, let recovery, let player = self.nativePlayer {
                            player.seek(to: CMTime(seconds: recovery.seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    guard self?.request?.id == next.id else { return }
                                    if recovery.playing { player.play() } else { player.pause() }
                                }
                            }
                        }
                    }
                }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item, queue: .main) { [weak self] notification in
                    let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                    Task { @MainActor [weak self] in
                        self?.nativeFailed(requestID: next.id, message: message ?? "原生播放中断。")
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.request?.id == next.id else { return }
                        self?.stateText = "播放结束"
                    }
                }
                nativePresented = false
                if recovery == nil { player.play() }
            } else {
                vlc = try VPPVLCSession(url: next.url, stereo: next.usesTextureOutput)
                // Flat video starts after its UIView has attached; SBS starts with its frame mailbox.
                if next.usesTextureOutput { vlc?.play() }
            }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            if next.engine == .native {
                nativeFailed(requestID: next.id, message: error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
                stateText = "播放失败"
            }
        }
    }

    private func nativeFailed(requestID: UUID, message: String) {
        guard let old = request, old.id == requestID, old.engine == .native,
              !isClosing, !isSwitchingEngine else { return }
        guard old.allowsNativeFallback else {
            errorMessage = message
            stateText = "播放失败"
            return
        }
        // One-way fallback. Transfer the existing file access grant; do not release it
        // between decoders. A newer open/stop invalidates this queued recovery.
        isSwitchingEngine = true
        stateText = "正在切换到 VLC"
        let recovery = (seconds: elapsed.isFinite ? max(0, elapsed) : 0, playing: wantsPlayback)
        openGeneration += 1
        let generation = openGeneration
        let previous = pendingOpen
        pendingOpen = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.openGeneration, self.request?.id == old.id else { return }
            await self.shutdown(releaseSecurityScope: false)
            guard generation == self.openGeneration else {
                if old.securityScoped { old.url.stopAccessingSecurityScopedResource() }
                return
            }
            self.start(PlaybackRequest(url: old.url, engine: .vlc, layout: old.layout,
                                       swapEyes: old.swapEyes, securityScoped: old.securityScoped, converts2D: old.converts2D, libraryID: old.libraryID, isCinema: old.isCinema),
                       recovery: (recovery.seconds, self.wantsPlayback), notice: "原生播放失败，已自动切换到 VLC。")
        }
    }

    func attachVLC(to view: UIView) {
        vlc?.attachDrawable(view)
        vlc?.play()
    }

    private func refresh() {
        guard !isSwitchingEngine else { return }
        if let player = nativePlayer {
            if player.status == .failed || player.currentItem?.status == .failed, let request {
                nativeFailed(requestID: request.id,
                             message: player.error?.localizedDescription ?? player.currentItem?.error?.localizedDescription ?? "原生播放失败。")
                return
            }
            elapsed = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            let seconds = player.currentItem?.duration.seconds ?? 0
            duration = seconds.isFinite ? max(0, seconds) : 0
            progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
            isPlaying = player.rate > 0
            if player.currentItem?.status == .readyToPlay { wantsPlayback = isPlaying }
            isSeekable = duration > 0 && !(player.currentItem?.seekableTimeRanges.isEmpty ?? true)
            if errorMessage == nil {
                if elapsed > 0 && duration > 0 && elapsed >= duration - 0.1 {
                    stateText = "播放结束"
                } else {
                    switch player.timeControlStatus {
                    case .playing: stateText = "播放中"
                    case .waitingToPlayAtSpecifiedRate: stateText = "正在缓冲"
                    default: stateText = "已暂停"
                    }
                }
            }
        } else if let vlc {
            progress = min(1, max(0, vlc.position))
            elapsed = vlc.elapsedSeconds; duration = vlc.durationSeconds
            isPlaying = vlc.playing; isSeekable = vlc.seekable
            stateText = vlc.stateText
            if vlc.failed { errorMessage = vlc.stateText }
            if let recovery = pendingVLCRecovery, vlc.seekable, duration > 0 {
                pendingVLCRecovery = nil
                if recovery.seconds > 0 {
                    vlc.seek(toFraction: min(recovery.seconds / duration, 0.999))
                }
                if !recovery.playing { vlc.setPaused(true) }
            }
        }
        if selectedSubtitle == "external" { subtitleText = SubtitleCue.text(at: elapsed - subtitleOffset, in: subtitleCues) }
        let now = ProcessInfo.processInfo.systemUptime
        if duration > 0, now - lastCheckpoint > 5 { checkpoint(); lastCheckpoint = now }
        if vlc != nil, now - lastTrackRefresh > 2 { loadTracks(); lastTrackRefresh = now }
    }

    func togglePlayback() {
        guard !isSwitchingEngine else { return }
        wantsPlayback = !isPlaying
        if let player = nativePlayer {
            if isPlaying { player.pause() }
            else {
                if duration > 0 && elapsed >= duration - 0.1 { player.seek(to: .zero) }
                player.play()
            }
        } else if let vlc {
            if isPlaying { vlc.setPaused(true) } else { vlc.play() }
        }
        refresh()
    }

    func seek(to fraction: Double) {
        guard isSeekable else { return }
        depthRevision += 1
        subtitleText = ""
        let bounded = min(1, max(0, fraction))
        if let player = nativePlayer {
            player.seek(to: CMTime(seconds: bounded * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else { vlc?.seek(toFraction: bounded) }
        progress = bounded
    }

    func copyVideoFrame() -> CVPixelBuffer? {
        if let output = videoOutput {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
            return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        }
        return vlc?.copyLatestPixelBuffer()
    }

    func stop() {
        openGeneration += 1
        let previous = pendingOpen
        pendingOpen = Task { [weak self] in
            await previous?.value
            await self?.shutdown()
        }
    }

    func waitForPendingChange() async { await pendingOpen?.value }

    func pauseForBackground() {
        wantsPlayback = false
        if let recovery = pendingVLCRecovery { pendingVLCRecovery = (recovery.seconds, false) }
        nativePlayer?.pause()
        vlc?.setPaused(true)
    }

    private func shutdown(releaseSecurityScope: Bool = true) async {
        checkpoint()
        trackTask?.cancel(); trackTask = nil
        audioGroup = nil; subtitleGroup = nil; captionReceiver = nil
        audioTracks = []; subtitleTracks = []; selectedAudio = ""; selectedSubtitle = "off"
        subtitleText = ""; subtitleCues = []; subtitleOffset = 0
        isClosing = true
        pollTask?.cancel(); pollTask = nil
        nativeStatus = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        nativePlayer?.pause()
        nativePlayer?.replaceCurrentItem(with: nil)
        nativePlayer = nil; videoOutput = nil
        nativePresented = false
        let old = request
        request = nil
        if let session = vlc {
            vlc = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.close { continuation.resume() }
            }
        }
        if releaseSecurityScope, old?.securityScoped == true { old?.url.stopAccessingSecurityScopedResource() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isPlaying = false; isSeekable = false
        stateText = "已停止"
        isClosing = false
        isSwitchingEngine = false
        pendingVLCRecovery = nil
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
