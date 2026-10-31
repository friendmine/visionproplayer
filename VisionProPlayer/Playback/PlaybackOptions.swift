import Foundation

enum PlaybackEngine: String, CaseIterable, Identifiable {
    case automatic, native, vlc
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "自动选择"
        case .native: "Apple 原生"
        case .vlc: "VLCKit"
        }
    }

    func resolved(for url: URL) -> Self {
        guard self == .automatic else { return self }
        return ["mkv", "avi", "webm", "ts", "m2ts", "flv", "wmv"].contains(url.pathExtension.lowercased()) ? .vlc : .native
    }
}

enum StereoLayout: String, CaseIterable, Identifiable {
    case flat, halfSBS, fullSBS
    var id: Self { self }
    var title: String {
        switch self {
        case .flat: "2D / 原生空间视频"
        case .halfSBS: "Half SBS（左右压缩）"
        case .fullSBS: "Full SBS（左右完整）"
        }
    }
    var isStereo: Bool { self != .flat }

    func displayAspect(width: Int, height: Int) -> Float {
        guard width > 0, height > 0 else { return 16 / 9 }
        let aspect = Float(width) / Float(height)
        return self == .fullSBS ? aspect / 2 : aspect
    }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let engine: PlaybackEngine
    let layout: StereoLayout
    let swapEyes: Bool
    let securityScoped: Bool
}
