import Photos
import PhotosUI
import SwiftUI

struct PhotoLibraryBrowser: View {
    let select: (PHAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var assets: [PHAsset] = []
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var loading = true
    @State private var managingAccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("直接播放系统相册的视频，只保存续播和观看偏好。iCloud 视频可能需要系统下载；空间视频使用原片的立体版本。")
                        .font(.callout).foregroundStyle(.secondary)
                    if loading { ProgressView("正在读取相册…").frame(maxWidth: .infinity) }
                    else if status == .authorized || status == .limited {
                        if status == .limited {
                            Button("管理可访问视频", systemImage: "photo.badge.plus") { managingAccess = true }
                        }
                        if assets.isEmpty {
                            ContentUnavailableView("没有可访问的视频", systemImage: "photo.on.rectangle", description: Text("可在“管理可访问视频”或系统设置中允许访问需要播放的视频。"))
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 18)], spacing: 20) {
                                ForEach(assets, id: \.localIdentifier) { asset in
                                    Button { select(asset); dismiss() } label: {
                                        PhotoAssetTile(asset: asset)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("需要相册读取权限", systemImage: "lock", description: Text("可以只允许访问选定的视频。也可返回片库，选择“从相册保存离线副本”。"))
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }.padding(24)
            }
            .navigationTitle("从相册播放")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("刷新", systemImage: "arrow.clockwise") { reload() } }
            }
        }.frame(width: 760, height: 620)
            .task {
                if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                guard !Task.isCancelled else { return }
                reload()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
            .sheet(isPresented: $managingAccess, onDismiss: reload) {
                LimitedPhotosAccess { managingAccess = false }.frame(width: 600, height: 500)
            }
    }

    private func reload() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { assets = []; loading = false; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let results = PHAsset.fetchAssets(with: .video, options: options)
        assets = (0..<results.count).map { results.object(at: $0) }
        loading = false
    }
}

private struct PhotoAssetTile: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black.opacity(0.35)
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "video").font(.largeTitle) }
            }.frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "相册视频")
                .font(.caption).lineLimit(1)
            Text("\(asset.mediaSubtypes.contains(.spatialMedia) ? "空间视频" : "视频") · \(PlayerModel.clock(asset.duration))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .task(id: asset.localIdentifier) {
                let loaded = await PhotoPlaybackSource.thumbnail(asset.localIdentifier, size: CGSize(width: 360, height: 240))
                if !Task.isCancelled { image = loaded }
            }
    }
}

private struct LimitedPhotosAccess: UIViewControllerRepresentable {
    let done: () -> Void
    func makeUIViewController(context: Context) -> LimitedPhotosController {
        let controller = LimitedPhotosController(); controller.done = done; return controller
    }
    func updateUIViewController(_ controller: LimitedPhotosController, context: Context) {}
}

private final class LimitedPhotosController: UIViewController {
    var done: (() -> Void)?
    private var presented = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presented else { return }
        presented = true
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
            Task { @MainActor in self?.done?() }
        }
    }
}
