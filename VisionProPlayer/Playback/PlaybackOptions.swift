import Foundation
import CoreGraphics

enum PlaybackEngine: String, CaseIterable, Identifiable, Codable {
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

enum StereoLayout: String, CaseIterable, Identifiable, Codable {
    case flat, halfSBS, fullSBS, halfOU, fullOU
    var id: Self { self }
    var title: String {
        switch self {
        case .flat: "普通 2D"
        case .halfSBS: "左右 3D · 半宽"
        case .fullSBS: "左右 3D · 全宽"
        case .halfOU: "上下 3D · 半高"
        case .fullOU: "上下 3D · 全高"
        }
    }
    var isStereo: Bool { self != .flat }

    var isTopBottom: Bool { self == .halfOU || self == .fullOU }

    // Coordinates after the renderer's vertical orientation correction: y=0
    // is the source's top. CGImage thumbnails also address their top at y=0.
    func eyeRegions(width: Int, height: Int) -> (left: CGRect, right: CGRect) {
        let w = isStereo && !isTopBottom ? width / 2 : width
        let h = isTopBottom ? height / 2 : height
        return (CGRect(x: 0, y: 0, width: w, height: h),
                CGRect(x: isStereo && !isTopBottom ? w : 0, y: isTopBottom ? h : 0, width: w, height: h))
    }

    func displayAspect(width: Int, height: Int) -> Float {
        guard width > 0, height > 0 else { return 16 / 9 }
        let aspect = Float(width) / Float(height)
        return self == .fullSBS ? aspect / 2 : (self == .fullOU ? aspect * 2 : aspect)
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
    var converts2D = false
    var libraryID: UUID?
    var isCinema = false
    var isSpatialVideo = false
    var usesTextureOutput: Bool { !isSpatialVideo && (layout.isStereo || converts2D || isCinema) }
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
