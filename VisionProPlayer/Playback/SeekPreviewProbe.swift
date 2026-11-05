import Foundation
import CoreGraphics
import UIKit

extension PlayerModel {
    #if DEBUG
    func runSeekPreviewProbe() async {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<80 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func color(_ image: CGImage) -> [UInt8] {
            // Rasterize the whole CGImage before reading one pixel. Native
            // AVFoundation images may use extended/packed source formats.
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let offset = ((height / 4) * width + width / 4) * 4
            return Array(pixels[offset..<(offset + 3)])
        }
        for engine in [PlaybackEngine.native, .vlc] {
            let url = URL.documentsDirectory.appending(path: engine == .native ? "SeekPreview.mp4" : "SeekPreview.mkv")
            for layout in [StereoLayout.flat, .fullSBS, .halfSBS, .fullOU, .halfOU] {
                let request = PlaybackRequest(url: url, engine: engine, layout: layout, swapEyes: false, securityScoped: false)
                let reader = SeekFrameReader(request)
                for second in [1.0, 4.0] {
                    for swapped in (layout.isStereo ? [false, true] : [false]) {
                        let frame = await reader.frame(at: second, swapped: swapped)
                        if layout == .flat, second == 1, let frame,
                           let data = UIImage(cgImage: frame.image).pngData() {
                            try? data.write(to: URL.documentsDirectory.appending(path: "seek-preview-\(engine.rawValue).png"))
                        }
                        let actual = frame.map { color($0.image) } ?? []
                        let firstHalf = second < 3
                        let expected: [UInt8]
                        if layout.isTopBottom && swapped { expected = firstHalf ? [0, 0, 255] : [255, 0, 0] }
                        else if layout.isStereo && swapped { expected = firstHalf ? [0, 255, 0] : [255, 255, 255] }
                        else { expected = firstHalf ? [255, 0, 0] : [0, 0, 255] }
                        let correct = actual.count == 3 && zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 30 }
                        let expectedAspect: CGFloat = layout == .fullSBS ? 2.0 / 3 : layout == .fullOU ? 8.0 / 3 : 4.0 / 3
                        check("\(engine.rawValue)-\(layout.rawValue)-\(second)-swap-\(swapped)",
                              correct && abs((frame?.seconds ?? -10) - second) < 0.3
                                && abs((frame?.aspect ?? 0) - expectedAspect) < 0.025)
                        checks[checks.count - 1]["actualColor"] = actual
                        checks[checks.count - 1]["expectedColor"] = expected
                        checks[checks.count - 1]["actualTime"] = frame?.seconds ?? -1
                        checks[checks.count - 1]["aspect"] = frame?.aspect ?? 0
                    }
                }
            }
            open(url, layout: .flat, engine: engine)
            await waitForPendingChange()
            await wait { duration > 0 && isPlaying && isSeekable }
            if isPlaying { togglePlayback() }
            try? await Task.sleep(for: .milliseconds(400))
            let position = elapsed
            guard let request else { check("request-created", false); continue }
            let preview = seekPreview
            preview.show(request: request, fraction: 0.2, duration: duration, swapped: false)
            preview.show(request: request, fraction: 0.8, duration: duration, swapped: false)
            await wait { preview.frame != nil || preview.unavailable }
            await wait { (preview.frame?.seconds ?? 0) > 4 }
            check("\(engine.rawValue)-preview-keeps-main-player-paused", !isPlaying && abs(elapsed - position) < 0.2
                  && (preview.frame?.seconds ?? 0) > 4 && request.id == self.request?.id)
            checks[checks.count - 1]["position"] = position
            checks[checks.count - 1]["elapsed"] = elapsed
            checks[checks.count - 1]["previewTime"] = preview.frame?.seconds ?? -1
            checks[checks.count - 1]["playing"] = isPlaying
            preview.show(request: request, fraction: 0.3, duration: duration, swapped: false)
            preview.end()
            try? await Task.sleep(for: .milliseconds(700))
            check("\(engine.rawValue)-dismiss-rejects-late-frame", preview.activeID == nil && preview.frame == nil)
            seek(to: 0.8)
            await wait { abs(elapsed - duration * 0.8) < 0.4 }
            check("\(engine.rawValue)-release-seek-reaches-preview-time", abs(elapsed - duration * 0.8) < 0.4 && !isPlaying)
            checks[checks.count - 1]["elapsed"] = elapsed
            checks[checks.count - 1]["target"] = duration * 0.8
        }
        returnToLibrary()
        await waitForPendingChange()
        let report = smokeMetadata().merging([
            "sample": "seek-preview", "checks": checks,
            "passed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Real native/VLC independent frame extraction, known colors at two times, all packed layouts/eye order, rapid targets, dismissal and paused-player isolation. UI placement and gesture comfort require wearer confirmation."
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appending(path: "smoke-seek-preview.json"), options: .atomic)
        }
    }
    #endif
}
