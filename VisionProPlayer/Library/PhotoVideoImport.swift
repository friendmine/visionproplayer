import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The picker URL is temporary. Copy it while the transfer is valid; never load
/// a whole movie into Data or transcode away its multiview tracks.
final class PhotoVideoTransfer: Transferable, Sendable {
    let url: URL
    let name: String
    private let directory: URL
    private init(url: URL, name: String, directory: URL) { self.url = url; self.name = name; self.directory = directory }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try stage(received.file) }
    }
    static func stage(_ source: URL) throws -> PhotoVideoTransfer {
        let folder = URL.temporaryDirectory.appending(path: "photo-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = source.lastPathComponent
            let target = folder.appending(path: name)
            try FileManager.default.copyItem(at: source, to: target)
            try Task.checkCancellation()
            return PhotoVideoTransfer(url: target, name: name, directory: folder)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Observable
final class PhotoVideoImporter {
    private(set) var isImporting = false
    private(set) var fraction: Double?
    @ObservationIgnored private var transfer: Progress?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?

    func cancel() {
        token = nil; transfer?.cancel(); transfer = nil
        monitor?.cancel(); monitor = nil; isImporting = false; fraction = nil
    }
    func begin(_ item: PhotosPickerItem, model: PlayerModel) {
        cancel()
        let id = UUID(); token = id; isImporting = true
        transfer = item.loadTransferable(type: PhotoVideoTransfer.self) { [weak self, weak model] result in
            Task { @MainActor in
                guard let self, let model, self.token == id else { return }
                self.monitor?.cancel(); self.monitor = nil; self.transfer = nil; self.token = nil
                do {
                    guard let video = try result.get() else { throw ImportError.noVideo }
                    let film = try model.library.importPhoto(video)
                    self.isImporting = false
                    model.openFilm(film)
                } catch {
                    self.isImporting = false
                    model.errorMessage = "无法导入相册视频。请确认 iCloud 视频已下载且设备有足够空间，再重试。\n\(error.localizedDescription)"
                }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.token == id else { return }
                if let transfer = self.transfer, transfer.totalUnitCount > 0 { self.fraction = min(1, max(0, transfer.fractionCompleted)) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    enum ImportError: LocalizedError {
        case noVideo, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .noVideo: "系统没有提供可读取的视频文件。"
            case .storageUnavailable: "片库当前无法保存，请先解决存储错误。"
            }
        }
    }
}
