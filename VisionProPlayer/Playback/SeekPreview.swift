import AVFoundation
import Observation
import UIKit

struct SeekPreviewFrame {
    let image: CGImage
    let aspect: CGFloat
    let seconds: Double
}

final class SeekFrameReader {
    let request: PlaybackRequest
    private let scoped: Bool
    private let generator: AVAssetImageGenerator
    private lazy var vlc = VPPSeekThumbnails(url: request.url)

    init(_ request: PlaybackRequest) {
        self.request = request
        scoped = request.url.isFileURL && request.url.startAccessingSecurityScopedResource()
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 448, height: 336)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
    }

    deinit { if scoped { request.url.stopAccessingSecurityScopedResource() } }
    func cancelNativeRead() { generator.cancelAllCGImageGeneration() }

    func frame(at seconds: Double, swapped: Bool) async -> SeekPreviewFrame? {
        let image: CGImage
        let time: Double
        if request.engine == .vlc {
            let (data, actualTime): (Data?, Double) = await withCheckedContinuation { continuation in
                vlc.fetch(at: seconds) { data, time in continuation.resume(returning: (data, time)) }
            }
            guard let data, let decoded = UIImage(data: data)?.cgImage else { return nil }
            image = decoded
            time = actualTime.isFinite && actualTime >= 0 ? actualTime : seconds
        } else {
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { generator.cancelAllCGImageGeneration() }
            }
            defer { timeout.cancel() }
            guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
            image = result.image
            time = result.actualTime.seconds
        }
        let layout = request.layout
        let aspect = CGFloat(layout.displayAspect(width: image.width, height: image.height))
        if layout.isStereo {
            let regions = layout.eyeRegions(width: image.width, height: image.height)
            guard let eye = image.cropping(to: swapped ? regions.right : regions.left) else { return nil }
            return SeekPreviewFrame(image: eye, aspect: aspect, seconds: time)
        }
        return SeekPreviewFrame(image: image, aspect: aspect, seconds: time)
    }
}

@MainActor @Observable
final class SeekPreview {
    private(set) var activeID: UUID?
    private(set) var frame: SeekPreviewFrame?
    private(set) var unavailable = false
    private struct Key: Hashable {
        let halfSecond: Int
        let swapped: Bool
    }
    private struct Target {
        let key: Key
        let seconds: Double
        let session: Int
    }
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var reader: SeekFrameReader?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var cache: [Key: SeekPreviewFrame] = [:]
    @ObservationIgnored private var insertionOrder: [Key] = []

    #if DEBUG
    @ObservationIgnored private var uiEvents: [[String: Any]] = []
    @ObservationIgnored private var lastUIEventTime = 0.0
    func recordUIEvent(_ event: String, details: [String: Any] = [:]) {
        let now = ProcessInfo.processInfo.systemUptime
        if event == "slider-value", now - lastUIEventTime < 0.25 { return }
        lastUIEventTime = now
        var entry: [String: Any] = ["event": event, "uptime": now,
            "active": activeID != nil, "frameTime": frame?.seconds ?? -1,
            "unavailable": unavailable]
        entry.merge(details) { _, new in new }
        uiEvents.append(entry)
        if uiEvents.count > 80 { uiEvents.removeFirst() }
        if let data = try? JSONSerialization.data(withJSONObject: uiEvents, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "seek-preview-interaction.json"), options: .atomic)
        }
    }
    #endif

    func show(request: PlaybackRequest, fraction: Double, duration: Double, swapped: Bool) {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return }
        if reader?.request.id != request.id {
            reset()
            reader = SeekFrameReader(request)
        }
        activeID = request.id
        let end = max(0, duration - 0.05)
        let seconds = min(end, max(0, fraction * duration))
        let key = Key(halfSecond: Int((seconds * 2).rounded()), swapped: request.layout.isStereo && swapped)
        guard target?.key != key else { return }
        target = Target(key: key, seconds: min(end, Double(key.halfSecond) / 2), session: session)
        unavailable = false
        if let cached = cache[key] { frame = cached; return }
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    // One read in flight and one latest target, even across a quick release/re-grab.
    private func drain() async {
        defer { worker = nil }
        while target != nil {
            try? await Task.sleep(for: .milliseconds(70))
            guard let next = target, let reader else { return }
            if let cached = cache[next.key] { frame = cached; return }
            let result = await reader.frame(at: next.seconds, swapped: next.key.swapped)
            guard next.session == session else { continue }
            if let result {
                if cache.count >= 24 { cache.removeValue(forKey: insertionOrder.removeFirst()) }
                cache[next.key] = result
                insertionOrder.append(next.key)
                // Keep serving completed, time-labelled frames while the hand moves.
                // A newer cache hit must always win over an older outstanding read.
                frame = target.flatMap { cache[$0.key] } ?? result
            }
            #if DEBUG
            recordUIEvent("frame-completed", details: ["requestedTime": next.seconds, "success": result != nil])
            #endif
            if target?.key == next.key {
                unavailable = result == nil
                if unavailable { frame = nil }
                return
            }
        }
    }

    func end() {
        session += 1
        target = nil
        activeID = nil
        frame = nil
        unavailable = false
        reader?.cancelNativeRead()
    }

    func reset() {
        end()
        reader = nil
        cache.removeAll()
        insertionOrder.removeAll()
    }
}
