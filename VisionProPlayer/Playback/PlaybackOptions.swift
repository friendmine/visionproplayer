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
    var allowsNativeFallback = false
}

/// Documents-based real-film fixtures shared by manual and automated checks.
enum CompatibilitySample: String, CaseIterable, Identifiable {
    case hevcMP4 = "hevc-mp4"
    case hevcMKV = "hevc-mkv"
    case halfH264Native = "half-h264-native"
    case halfH264VLC = "half-h264-vlc"
    case halfHEVCNative = "half-hevc-native"
    case halfHEVCVLC = "half-hevc-vlc"

    var id: String { rawValue }
    var engine: PlaybackEngine {
        switch self {
        case .hevcMP4, .halfH264Native, .halfHEVCNative: .native
        default: .vlc
        }
    }
    var layout: StereoLayout {
        self == .hevcMP4 || self == .hevcMKV ? .flat : .halfSBS
    }
    var fileStem: String {
        switch self {
        case .hevcMP4, .hevcMKV: "BBB-HEVC-2D-30s"
        case .halfH264Native, .halfH264VLC: "BBB-H264-HalfSBS-30s"
        case .halfHEVCNative, .halfHEVCVLC: "BBB-HEVC-HalfSBS-30s"
        }
    }
    var fileExtension: String { engine == .native ? "mp4" : "mkv" }
    var url: URL { URL.documentsDirectory.appending(path: "\(fileStem).\(fileExtension)") }
    var title: String {
        let codec = fileStem.contains("H264") ? "H.264" : "H.265"
        return "\(codec) \(fileExtension.uppercased()) · \(layout.isStereo ? "Half SBS" : "2D")"
    }
}
