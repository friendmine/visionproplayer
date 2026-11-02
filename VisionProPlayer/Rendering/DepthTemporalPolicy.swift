import Foundation

/// A small, exposure-compensated translation search prevents camera pans from
/// being treated as cuts. This is a scene-reset heuristic, not dense optical flow.
enum DepthSceneChange {
    static let columns = 16, rows = 12
    static func detected(previous: [Float], current: [Float]) -> Bool {
        guard previous.count == columns * rows, current.count == previous.count,
              previous.allSatisfy(\.isFinite), current.allSatisfy(\.isFinite) else { return true }
        let count = Float(previous.count)
        let difference = zip(previous, current).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / count
        guard difference > 0.16 else { return false }
        let oldMean = previous.reduce(0, +) / count, newMean = current.reduce(0, +) / count
        // Do not carry geometry through black frames or a fade to black.
        if min(oldMean, newMean) < 0.025 && max(oldMean, newMean) > 0.10 { return true }
        let exposure = max(-0.20, min(0.20, newMean - oldMean))
        var best = Float.greatestFiniteMagnitude
        var unshifted = Float.greatestFiniteMagnitude
        for sy in -2...2 { for sx in -4...4 {
            let dx = Float(sx) * 0.5, dy = Float(sy) * 0.5
            var residual: Float = 0
            for y in 2..<(rows - 2) { for x in 2..<(columns - 2) {
                let px = Float(x) + dx, py = Float(y) + dy
                let ix = Int(px), iy = Int(py), tx = px - Float(ix), ty = py - Float(iy)
                let nx = min(columns - 1, ix + 1)
                let a = previous[iy * columns + ix] * (1 - tx) + previous[iy * columns + nx] * tx
                let b = previous[(iy + 1) * columns + ix] * (1 - tx) + previous[(iy + 1) * columns + nx] * tx
                residual += abs(current[y * columns + x] - (a * (1 - ty) + b * ty + exposure))
            }}
            let error = residual / Float((rows - 4) * (columns - 4))
            if sx == 0 && sy == 0 { unshifted = error }
            best = min(best, error)
        }}
        // A weak accidental match between unrelated scenes is not evidence of
        // motion. Require either a close match or a substantial improvement
        // over the unshifted, exposure-compensated residual.
        return best > 0.12 || (best > 0.04 && best > unshifted * 0.60)
    }
}

/// Fade recovered depth in instead of snapping from flat to full disparity.
/// The 150 ms stale-depth limit remains unchanged. Paused adjustments settle
/// immediately; this state never schedules extra video frames by itself.
struct DepthPresentationEnvelope {
    private var generation = -1
    private var previousTime: Double?
    private(set) var gain: Float = 0
    mutating func update(now: Double, capturedAt: Double?, generation: Int, playing: Bool) -> Float {
        if generation != self.generation { self.generation = generation; gain = 0; previousTime = nil }
        let elapsed = max(0, min(1.0 / 15.0, now - (previousTime ?? (now - 1.0 / 30.0))))
        previousTime = now
        guard let capturedAt else { gain = 0; return gain }
        guard playing else { gain = 1; return gain }
        let age = max(0, now - capturedAt)
        let t = Float(max(0, min(1, (age - 0.12) / 0.03)))
        let freshness = 1 - t * t * (3 - 2 * t)
        gain = min(freshness, gain + Float(elapsed / 0.24))
        return gain
    }
}
