import AVFoundation
import Photos
import UIKit

/// A cancellable PhotoKit request. The app retains no movie URL or video copy.
@MainActor
final class PhotoPlaybackSource {
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<AVPlayerItem, Error>?
    private var generation = 0

    static func asset(_ identifier: String) throws -> PHAsset {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw AccessError.permission }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else { throw AccessError.unavailable }
        return asset
    }

    func load(_ identifier: String, progress: @escaping (Double) -> Void) async throws -> AVPlayerItem {
        cancel()
        let asset = try Self.asset(identifier)
        let token = generation
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        // Keep the original multiview tracks for spatial recordings. Ordinary
        // edited videos use Photos' current composition, including its audio mix.
        options.version = asset.mediaSubtypes.contains(.spatialMedia) ? .original : .current
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor in
                guard self?.generation == token else { return }
                progress(value)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.requestID = nil
                    let pending = self.continuation; self.continuation = nil
                    if cancelled { pending?.resume(throwing: CancellationError()) }
                    else if let item { pending?.resume(returning: item) }
                    else { pending?.resume(throwing: AccessError.loadFailed) }
                }
            }
        }
    }

    static func thumbnail(_ identifier: String, size: CGSize) async -> UIImage? {
        guard let asset = try? asset(identifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func cancel() {
        generation += 1
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    enum AccessError: LocalizedError {
        case permission, unavailable, loadFailed, nativeOnly
        var errorDescription: String? {
            switch self {
            case .permission: "相册读取权限已关闭。请在系统设置中允许访问所需视频，或使用“从相册保存离线副本”。"
            case .unavailable: "相册视频已删除，或不在允许访问的范围内。请打开“从相册播放”，管理可访问视频后重试。"
            case .loadFailed: "暂时无法读取相册视频。请检查网络或先在系统相册打开该视频，再重试。"
            case .nativeOnly: "相册直接播放使用 Apple 原生引擎。如需 VLC，请通过“从相册保存离线副本”打开。"
            }
        }
    }
}
