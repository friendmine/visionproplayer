import Foundation
import Observation
import AVFoundation
import UIKit

enum CaptionSize: String {
    case small, standard, large
}

struct FilmPreferences: Codable, Equatable {
    var layout: StereoLayout = .flat
    var converts2D = false
    var strength: Float = 0.35
    var popOut: Float? // Missing in older libraries means the original balanced depth.
    var proportionProtection: Bool? // Missing in older libraries enables protection.
    var depthPreset: DepthPreset?
    var swapped = false
    var subtitleFile: String?
    var subtitleOffset = 0.0

    var depthEffect: DepthEffect {
        get { DepthEffect(strength: strength, popOut: popOut ?? 0, proportionProtection: proportionProtection ?? true, preset: depthPreset) }
        set {
            strength = newValue.strength
            popOut = newValue.popOut
            proportionProtection = newValue.proportionProtection
            depthPreset = newValue.preset
        }
    }
}

struct LibraryFilm: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var location: String
    var bookmark: Data?
    var photoFile: String?
    var isSpatialVideo: Bool?
    var favorite = false
    var addedAt = Date()
    var lastOpened: Date?
    var position = 0.0
    var duration = 0.0
    var preferences = FilmPreferences()
    var isNetwork: Bool { URL(string: location)?.isFileURL == false }
    var completed: Bool { duration > 0 && position >= duration - min(10, duration * 0.05) }
    var resumable: Bool { position > 2 && !completed }
    var sourceDescription: String { photoFile != nil ? "相册导入" : isNetwork ? (URL(string: location)?.host ?? "网络影片") : "本地影片" }
}

@MainActor @Observable
final class MediaLibrary {
    private(set) var films: [LibraryFilm] = []
    var error: String?
    var thumbnailRevision = 0
    var focusViewing = true { didSet { defaults.set(focusViewing, forKey: "focusViewing") } }
    var resumePlayback = true { didSet { defaults.set(resumePlayback, forKey: "resumePlayback") } }
    var screenWidth: Float = 3 { didSet { defaults.set(screenWidth, forKey: "screenWidth") } }
    var screenDistance: Float = 3 { didSet { defaults.set(screenDistance, forKey: "screenDistance") } }
    var screenHeight: Float = 1.5 { didSet { defaults.set(screenHeight, forKey: "screenHeight") } }
    var externalCaptionSize: CaptionSize = .standard {
        didSet { defaults.set(externalCaptionSize.rawValue, forKey: "externalCaptionSize") }
    }
    var externalCaptionAtTop = false {
        didSet { defaults.set(externalCaptionAtTop, forKey: "externalCaptionAtTop") }
    }
    var darkCinema = false { didSet { defaults.set(darkCinema, forKey: "darkCinema") } }
    private(set) var defaultDepthEffect: DepthEffect = .natural
    private var persistenceAvailable = true
    private let root: URL
    private let defaults: UserDefaults
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "MediaLibrary", directoryHint: .isDirectory)
        focusViewing = defaults.object(forKey: "focusViewing") as? Bool ?? true
        resumePlayback = defaults.object(forKey: "resumePlayback") as? Bool ?? true
        screenWidth = min(5, max(1.5, defaults.float(forKey: "screenWidth") == 0 ? 3 : defaults.float(forKey: "screenWidth")))
        screenDistance = min(6, max(2, defaults.float(forKey: "screenDistance") == 0 ? 3 : defaults.float(forKey: "screenDistance")))
        screenHeight = min(2.2, max(1, defaults.float(forKey: "screenHeight") == 0 ? 1.5 : defaults.float(forKey: "screenHeight")))
        externalCaptionSize = defaults.string(forKey: "externalCaptionSize").flatMap(CaptionSize.init(rawValue:)) ?? .standard
        externalCaptionAtTop = defaults.bool(forKey: "externalCaptionAtTop")
        darkCinema = defaults.bool(forKey: "darkCinema")
        if let data = defaults.data(forKey: "defaultDepthEffect"),
           let effect = try? JSONDecoder().decode(DepthEffect.self, from: data) {
            defaultDepthEffect = effect.normalized
        }
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let file = self.root.appending(path: "library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                films = try JSONDecoder().decode([LibraryFilm].self, from: Data(contentsOf: file))
            }
        } catch {
            // Preserve unreadable records before allowing a fresh library to be saved.
            let source = self.root.appending(path: "library.json")
            do {
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: self.root.appending(path: "library-recovery-\(UUID().uuidString).json"))
                    self.error = "无法读取片库记录，已保留恢复副本。原影片未被更改。"
                } else { persistenceAvailable = false; self.error = "无法访问片库存储。" }
            } catch {
                persistenceAvailable = false
                self.error = "无法读取片库记录，原记录已保留，暂不覆盖保存。"
            }
        }
    }
    var recent: [LibraryFilm] { films.sorted { ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt) } }
    func saveDefaultDepthEffect(_ effect: DepthEffect) {
        let effect = effect.normalized
        guard let data = try? JSONEncoder().encode(effect) else { return }
        defaults.set(data, forKey: "defaultDepthEffect")
        defaultDepthEffect = effect
    }
    var hasWatchHistory: Bool { films.contains { $0.lastOpened != nil || $0.position > 0 } }
    func clearWatchHistory() throws {
        guard persistenceAvailable else { throw LibraryError.storageUnavailable }
        let cleared = films.map { film in
            var copy = film
            copy.lastOpened = nil
            copy.position = 0
            return copy
        }
        // Publish only after saving succeeds, so a failed clear can be retried.
        try JSONEncoder().encode(cleared).write(to: root.appending(path: "library.json"), options: .atomic)
        films = cleared
    }
    func updateProgress(_ id: UUID, seconds: Double, duration: Double) {
        // A delayed checkpoint after clearing must not restore old progress.
        // Opening the film again explicitly sets lastOpened and enables saving.
        guard film(id)?.lastOpened != nil else { return }
        update(id) { $0.position = seconds; $0.duration = duration }
    }
    func film(_ id: UUID) -> LibraryFilm? { films.first { $0.id == id } }
    func thumbnailURL(_ id: UUID) -> URL { root.appending(path: "\(id.uuidString).jpg") }
    func subtitleURL(_ name: String) -> URL { root.appending(path: name) }
    private func save() {
        guard persistenceAvailable else { return }
        do { try JSONEncoder().encode(films).write(to: root.appending(path: "library.json"), options: .atomic) }
        catch { self.error = "无法保存片库记录：\(error.localizedDescription)" }
    }
    func update(_ id: UUID, _ change: (inout LibraryFilm) -> Void) {
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        change(&films[index]); save()
    }
    @discardableResult func add(_ url: URL, title: String? = nil) throws -> LibraryFilm {
        if let existing = films.first(where: { $0.location == url.absoluteString }) { return existing }
        // App updates may relocate its container. Resolve bookmarks before adding
        // another record for the same file under its new absolute path.
        if url.isFileURL {
            for existing in films where URL(string: existing.location)?.lastPathComponent == url.lastPathComponent {
                if let resolved = try? resolve(existing), resolved.standardizedFileURL == url.standardizedFileURL {
                    update(existing.id) { $0.location = url.absoluteString }
                    return film(existing.id) ?? existing
                }
            }
        }
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = url.isFileURL ? try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        var film = LibraryFilm(title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "网络影片",
                               location: url.absoluteString, bookmark: bookmark)
        film.preferences.depthEffect = defaultDepthEffect
        // Only explicit naming conventions are hints; never infer SBS just from width.
        let name = url.lastPathComponent.lowercased()
        if name.contains("halfsbs") || name.contains("hsbs") || name.contains("half-sbs") { film.preferences.layout = .halfSBS }
        else if name.contains("fullsbs") || name.contains("full-sbs") || name.hasPrefix("bbb-sbs-") { film.preferences.layout = .fullSBS }
        else if name.contains("half-ou") || name.contains("halfou") || name.contains("half-tab") { film.preferences.layout = .halfOU }
        else if name.contains("full-ou") || name.contains("fullou") || name.contains("full-tab") || name.contains("_stereo_abl") { film.preferences.layout = .fullOU }
        films.insert(film, at: 0); save()
        return film
    }
    private func photoURL(_ filename: String) -> URL? {
        guard filename == (filename as NSString).lastPathComponent, !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        return root.appending(path: "PhotoVideos", directoryHint: .isDirectory).appending(path: filename)
    }
    func importPhoto(_ video: PhotoVideoTransfer) throws -> LibraryFilm {
        guard persistenceAvailable else { throw PhotoVideoImporter.ImportError.storageUnavailable }
        let ext = video.url.pathExtension.nilIfEmpty ?? "mov"
        let filename = UUID().uuidString + "." + ext
        let destination = photoURL(filename)!
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: video.url, to: destination)
            var film = LibraryFilm(title: (video.name as NSString).deletingPathExtension.nilIfEmpty ?? "相册视频", location: destination.absoluteString)
            film.preferences.depthEffect = defaultDepthEffect
            film.photoFile = filename
            let updated = [film] + films
            try JSONEncoder().encode(updated).write(to: root.appending(path: "library.json"), options: .atomic)
            films = updated
            return film
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func resolve(_ film: LibraryFilm) throws -> URL {
        var stale = false
        let url: URL
        if let photo = film.photoFile {
            guard let owned = photoURL(photo) else { throw LibraryError.unavailable }
            url = owned
        } else if let bookmark = film.bookmark {
            url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        } else if let direct = URL(string: film.location) { url = direct }
        else { throw LibraryError.unavailable }
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.isFileURL {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryError.unavailable }
            if stale {
                let renewed = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                update(film.id) { $0.bookmark = renewed; $0.location = url.absoluteString }
            }
        }
        return url
    }
    func relocate(_ id: UUID, to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        update(id) { $0.bookmark = bookmark; $0.location = url.absoluteString }
        try? FileManager.default.removeItem(at: thumbnailURL(id))
    }
    func remove(_ id: UUID) {
        let owned = film(id)?.photoFile.flatMap { photoURL($0) }
        let updated = films.filter { $0.id != id }
        do {
            guard persistenceAvailable else { throw PhotoVideoImporter.ImportError.storageUnavailable }
            try JSONEncoder().encode(updated).write(to: root.appending(path: "library.json"), options: .atomic)
            films = updated
            thumbnailTasks[id]?.cancel(); thumbnailTasks[id] = nil
            // Only an app-owned photo copy is removed, never a Photos asset or
            // an externally selected movie. Store-relative names survive updates.
            if let owned { try FileManager.default.removeItem(at: owned) }
            try? FileManager.default.removeItem(at: thumbnailURL(id))
        } catch { self.error = "无法完整移除记录或导入副本：\(error.localizedDescription)" }
    }
    func makeThumbnail(for film: LibraryFilm) {
        guard !film.isNetwork, thumbnailTasks[film.id] == nil,
              !FileManager.default.fileExists(atPath: thumbnailURL(film.id).path) else { return }
        thumbnailTasks[film.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.thumbnailTasks[film.id] = nil }
            do {
                let url = try self.resolve(film)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 600, height: 340)
                let result = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                guard !Task.isCancelled, self.film(film.id) != nil else { return }
                if let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.75) {
                    try data.write(to: self.thumbnailURL(film.id), options: .atomic)
                    // Publish a change so visible thumbnails reload.
                    self.thumbnailRevision += 1
                }
            } catch { /* Unsupported thumbnail codecs retain a neutral poster. */ }
        }
    }
    func importSubtitle(_ url: URL, for id: UUID) throws -> [SubtitleCue] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 { throw LibraryError.subtitleTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 5_000_000 else { throw LibraryError.subtitleTooLarge }
        let cues = try SubtitleCue.parse(data)
        let name = "\(id.uuidString)-subtitles.srt"
        try data.write(to: subtitleURL(name), options: .atomic)
        update(id) { $0.preferences.subtitleFile = name }
        return cues
    }
    enum LibraryError: LocalizedError {
        case unavailable, subtitleTooLarge, invalidSubtitle, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "找不到这部影片，或访问权限已失效。请重新定位文件。"
            case .subtitleTooLarge: "字幕文件过大，请选择小于 5 MB 的 SRT 或 WebVTT 文件。"
            case .invalidSubtitle: "无法读取字幕，请选择 UTF-8 或 UTF-16 编码的 SRT / WebVTT 文件。"
            case .storageUnavailable: "片库当前无法保存，请先解决存储错误。"
            }
        }
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
