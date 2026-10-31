import Foundation

@main
struct OptionsChecks {
    static func main() {
        precondition(PlaybackEngine.automatic.resolved(for: URL(filePath: "/Movies/clip.MKV")) == .vlc)
        precondition(PlaybackEngine.automatic.resolved(for: URL(string: "https://example.com/movie.mp4?token=test")!) == .native)
        precondition(PlaybackEngine.native.resolved(for: URL(filePath: "/clip.mkv")) == .native)
        precondition(PlaybackEngine.vlc.resolved(for: URL(filePath: "/clip.mp4")) == .vlc)
        // Full SBS has twice the per-eye width; half SBS needs horizontal expansion.
        precondition(abs(StereoLayout.fullSBS.displayAspect(width: 3840, height: 1080) - 16.0 / 9.0) < 0.001)
        precondition(abs(StereoLayout.halfSBS.displayAspect(width: 1920, height: 1080) - 16.0 / 9.0) < 0.001)
        precondition(StereoLayout.fullSBS.displayAspect(width: 0, height: 0).isFinite)
        print("PASS: engine routing, explicit overrides, Full/Half SBS aspect ratios")
    }
}
