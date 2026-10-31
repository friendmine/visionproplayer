import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class PlayerModel {
    var engineChoice: PlaybackEngine = .automatic
    var layoutChoice: StereoLayout = .flat
    var swapEyes = false
    var eyeCheck = false
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
    func openSample(_ url: URL, layout: StereoLayout, engine: PlaybackEngine) {
        eyeCheck = false
        swapEyes = false
        open(url, layout: layout, engine: engine)
    }

    func open(_ url: URL, layout: StereoLayout? = nil, engine: PlaybackEngine? = nil) {
        // Take access before the fileImporter callback returns; release only after decoder shutdown.
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        let selectedLayout = layout ?? layoutChoice
        let preference = engine ?? engineChoice
        let selectedEngine = preference.resolved(for: url)
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
            self.start(PlaybackRequest(url: url, engine: selectedEngine, layout: selectedLayout,
                                       swapEyes: self.swapEyes, securityScoped: scoped,
                                       allowsNativeFallback: preference == .automatic))
        }
    }

    private func start(_ next: PlaybackRequest, recovery: (seconds: Double, playing: Bool)? = nil,
                       notice: String? = nil) {
        request = next
        isSwitchingEngine = false
        playbackNotice = notice
        wantsPlayback = recovery?.playing ?? true
        pendingVLCRecovery = recovery
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
                if next.layout.isStereo {
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferMetalCompatibilityKey as String: true
                    ])
                    item.add(output)
                    videoOutput = output
                }
                let player = AVPlayer(playerItem: item)
                nativePlayer = player
                nativeStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    let message = item.error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.request?.id == next.id else { return }
                        if failed {
                            self.nativeFailed(requestID: next.id, message: message ?? "原生播放器无法打开此文件。")
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
                nativePresented = !next.layout.isStereo
                player.play()
            } else {
                vlc = try VPPVLCSession(url: next.url, stereo: next.layout.isStereo)
                // Flat video starts after its UIView has attached; SBS starts with its frame mailbox.
                if next.layout.isStereo { vlc?.play() }
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
                                       swapEyes: old.swapEyes, securityScoped: old.securityScoped),
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
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
