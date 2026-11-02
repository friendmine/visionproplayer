import Foundation
import Metal

// Exercise the app's actual encoder and read back its final displacement field.
// These fixtures measure projection-induced deformation, not anatomical truth.
let device = MTLCreateSystemDefaultDevice()!
let source = try String(contentsOfFile: "VisionProPlayer/Rendering/DepthStereo.metal", encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let projector = try StereoReprojector(device: device, library: library)
let queue = device.makeCommandQueue()!
func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: d)!
}
func require(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); fflush(stdout); exit(1) }
}
func distanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let delta = b - a, offset = p - a
    let dot = offset.x * delta.x + offset.y * delta.y
    let t = max(0, min(1, dot / (delta.x * delta.x + delta.y * delta.y)))
    let d = p - (a + t * delta)
    return sqrt(d.x * d.x + d.y * d.y)
}
let landmarks: [(String, SIMD2<Float>, SIMD2<Float>)] = [
    ("face-width", [0.43,0.22], [0.57,0.22]),
    ("face-height", [0.5,0.13], [0.5,0.31]),
    ("shoulder-width", [0.4,0.33], [0.6,0.33]),
    ("torso-height", [0.5,0.33], [0.5,0.62]),
    ("left-upper-arm", [0.4,0.33], [0.24,0.52]),
    ("left-forearm", [0.24,0.52], [0.18,0.32]),
    ("right-upper-arm", [0.6,0.33], [0.75,0.45]),
    ("right-forearm", [0.75,0.45], [0.82,0.67]),
    ("left-leg", [0.44,0.62], [0.39,0.94]),
    ("right-leg", [0.56,0.62], [0.67,0.93])
]
var cases = 0, protectedCases = 0
var protectedMin: Float = 1, protectedMax: Float = 1, baselineMin: Float = 1, baselineMax: Float = 1
var protectedLandmarkError: Float = 0, baselineLandmarkError: Float = 0
var largestHorizontal: Float = 0, largestVertical: Float = 0
for (width, height) in [(640,360), (360,640), (641,359)] {
    let color = texture(.rgba32Float, width, height), depth = texture(.r32Float, width, height)
    let left = texture(.rgba16Float, width, height), right = texture(.rgba16Float, width, height)
    var colors = [Float](repeating: 0, count: width * height * 4)
    var depths = [Float](repeating: 0, count: width * height)
    for pattern in 0..<3 {
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
            let point = SIMD2<Float>(u, v)
            var d: Float = 0.15 + 0.06 * u
            if pattern == 0 {
                d = Float((x * 13 + y * 29 + (x / 7) * 53) % 101) / 100
            } else if pattern == 1 {
                let hx = (u - 0.5) / 0.07, hy = (v - 0.22) / 0.09
                if hx * hx + hy * hy < 1 { d = 0.6 + 0.35 * max(0, 1 - abs(hx)) }
                if u > 0.4 && u < 0.6 && v > 0.31 && v < 0.62 { d = 0.65 + 0.18 * sin(v * 25) }
                for (i, segment) in landmarks.enumerated() where i >= 4 {
                    if distanceToSegment(point, segment.1, segment.2) < 0.018 { d = i % 2 == 0 ? 0.9 : 0.35 }
                }
            } else {
                d = v > 0.5 + 0.12 * sin(u * 19) ? 0.95 : 0.05
            }
            depths[y * width + x] = d
            let i = (y * width + x) * 4
            colors[i] = u; colors[i+1] = v; colors[i+2] = d; colors[i+3] = 1
        }}
        colors.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        for params in [SIMD4<Float>(0,1,0.04,0.012), [0.35,0,0.04,0.012], [0.35,0.6,0.04,0.012],
                       [0.35,1,0.04,0.012], [0.6,1,0.04,0.012], [1,1,0.03,0.012], [0.35,1,0.002,0.012]] {
            for enabled in [false, true] {
                let command = queue.makeCommandBuffer()!
                try projector.encode(color: color, depth: depth, parameters: params, protectProportions: enabled,
                    left: left, right: right, commands: command)
                let field = projector.outputDisparity!
                let copy = texture(.r32Float, field.width, field.height)
                let blit = command.makeBlitCommandEncoder()!
                blit.copy(from: field, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x:0,y:0,z:0),
                    sourceSize: MTLSize(width:field.width,height:field.height,depth:1), to: copy,
                    destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x:0,y:0,z:0))
                blit.endEncoding(); command.commit(); command.waitUntilCompleted()
                require(command.status == .completed, "GPU projection failed")
                let fw = field.width, fh = field.height
                var values = [Float](repeating: 0, count: fw * fh)
                values.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: fw * 4,
                    from: MTLRegionMake2D(0,0,fw,fh), mipmapLevel: 0) }
                require(values.allSatisfy { $0.isFinite && $0 >= -params.w * 0.5 - 0.000001 && $0 <= params.z * 0.5 + 0.000001 }, "Disparity caps or finite output")
                if params.x == 0 { require(values.allSatisfy { $0 == 0 }, "Zero must remain exactly flat") }
                for y in 0..<fh { require(values[y*fw] == 0 && values[(y+1)*fw-1] == 0, "Horizontal endpoints must stay fixed") }
                // Match the vertex shader's shared vertical average before
                // measuring the two triangles in every cell, in pixel units.
                var sampled = values
                for y in 0..<fh { for x in 0..<fw {
                    sampled[y*fw+x] = 0.5 * values[y*fw+x] + 0.25 * values[max(0,y-1)*fw+x] + 0.25 * values[min(fh-1,y+1)*fw+x]
                }}
                for y in 0..<(fh-1) { for x in 0..<(fw-1) {
                    let a = sampled[y*fw+x], b = sampled[y*fw+x+1]
                    let c = sampled[(y+1)*fw+x], d = sampled[(y+1)*fw+x+1]
                    for (gx, gy) in [(b-a,c-a), (d-c,d-b)] {
                        let dx = gx * Float(fw-1), dy = gy * Float(fh-1) * Float(width) / Float(height)
                        if enabled {
                            largestHorizontal = max(largestHorizontal, abs(dx)); largestVertical = max(largestVertical, abs(dy))
                            require(abs(dx) <= 0.07002 && abs(dy) <= 0.07002, "Both pixel-space derivatives must be bounded, including portrait and odd sizes")
                        }
                        for eye: Float in [-1,1] {
                            let a = 1 + eye * dx, b = eye * dy
                            let trace = a*a + b*b + 1
                            let discriminant = sqrt(max(0, trace*trace - 4*a*a))
                            let low = sqrt(max(0, (trace-discriminant)*0.5)), high = sqrt((trace+discriminant)*0.5)
                            if enabled {
                                protectedMin = min(protectedMin, low); protectedMax = max(protectedMax, high)
                                require(low >= 0.9009 && high <= 1.0991, "Local length in any direction must remain within 10% of the source")
                            } else { baselineMin = min(baselineMin, low); baselineMax = max(baselineMax, high) }
                        }
                    }
                }}
                func project(_ p: SIMD2<Float>, eye: Float) -> SIMD2<Float> {
                    let gx = p.x * Float(fw-1), gy = p.y * Float(fh-1)
                    let x = min(fw-2, Int(gx)), y = min(fh-2, Int(gy))
                    let fx = gx-Float(x), fy = gy-Float(y)
                    let a = sampled[y*fw+x], b = sampled[y*fw+x+1], c = sampled[(y+1)*fw+x], d = sampled[(y+1)*fw+x+1]
                    let shift = fx+fy <= 1 ? a*(1-fx-fy)+b*fx+c*fy : d*(fx+fy-1)+c*(1-fx)+b*(1-fy)
                    return SIMD2<Float>((p.x+eye*shift)*Float(width), p.y*Float(height))
                }
                if pattern == 1 {
                    for (name,a,b) in landmarks { for eye: Float in [-1,1] {
                        let original = (b-a) * SIMD2<Float>(Float(width),Float(height))
                        let output = project(b, eye: eye)-project(a, eye: eye)
                        let ratio = sqrt((output.x*output.x+output.y*output.y)/(original.x*original.x+original.y*original.y))
                        if enabled {
                            protectedLandmarkError = max(protectedLandmarkError, abs(ratio-1))
                            require(abs(ratio-1) <= 0.1, "Synthetic \(name) proportions")
                        } else { baselineLandmarkError = max(baselineLandmarkError, abs(ratio-1)) }
                    }}
                }
                var eyePixels: [[UInt16]] = []
                for target in [left,right] {
                    var pixels = [UInt16](repeating: 0, count: width * height * 4)
                    pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width*8,
                        from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
                    for i in stride(from: 3, to: pixels.count, by: 4) { require(Float16(bitPattern:pixels[i]) == 1, "Projection must leave no uncovered pixels") }
                    eyePixels.append(pixels)
                }
                if params.x == 0 { require(eyePixels[0] == eyePixels[1], "Zero-strength eye images must match") }
                cases += 1; if enabled { protectedCases += 1 }
            }
        }
    }
}
require(baselineMax > 1.1 && baselineLandmarkError > protectedLandmarkError,
        "Fixtures must expose pre-existing deformation and show improvement")
let report: [String: Any] = ["cases":cases, "protectedCases":protectedCases,
    "protectedLocalLengthRange":[protectedMin,protectedMax], "baselineLocalLengthRange":[baselineMin,baselineMax],
    "protectedMaximumLandmarkLengthError":protectedLandmarkError, "baselineMaximumLandmarkLengthError":baselineLandmarkError,
    "maximumProtectedHorizontalSlope":largestHorizontal, "maximumProtectedVerticalSlope":largestVertical,
    "scope":"Synthetic GPU projection fixtures; no human detection or wearer acceptance", "passed":true]
print(String(data:try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
