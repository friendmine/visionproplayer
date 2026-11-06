import Foundation
import AVFoundation

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw MediaLibrary.LibraryError.invalidSubtitle
        }
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        func seconds(_ value: String) -> Double? {
            let parts = value.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first!.replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard (2...3).contains(parts.count), parts.allSatisfy({ Double($0) != nil }) else { return nil }
            return parts.reduce(0) { $0 * 60 + Double($1)! }
        }
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let content = lines.dropFirst(index + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: content)) }
        }
        guard !cues.isEmpty else { throw MediaLibrary.LibraryError.invalidSubtitle }
        return cues.sorted { $0.start < $1.start }
    }
    static func text(at seconds: Double, in cues: [SubtitleCue]) -> String {
        // Binary search the most recent cue; bounded scan supports ordinary overlapping cues.
        var lo = 0, hi = cues.count
        while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start <= seconds { lo = mid + 1 } else { hi = mid } }
        return cues[max(0, lo - 16)..<lo].filter { $0.end > seconds }.map(\.text).joined(separator: "\n")
    }
}

final class CaptionReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var receive: ((String) -> Void)?
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        receive?(strings.map(\.string).joined(separator: "\n"))
    }
}
