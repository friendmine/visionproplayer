import Foundation
import Metal
import CoreImage
import CoreVideo

// Numerical GPU test independent of the neural model and of stereo perception.
let device = MTLCreateSystemDefaultDevice()!
let source = try String(contentsOfFile: "VisionProPlayer/Rendering/DepthStereo.metal", encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let reprojector = try StereoReprojector(device: device, library: library)
let queue = device.makeCommandQueue()!
let width = 1024, height = 64
func texture(_ format: MTLPixelFormat) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: d)!
}
let color = texture(.rgba32Float), depth = texture(.r32Float)
let left = texture(.rgba16Float), right = texture(.rgba16Float)
var colors = [Float](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let p = (y * width + x) * 4
        colors[p] = Float(x) / Float(width-1); colors[p+1] = Float(y) / Float(height-1); colors[p+3] = 1
    }
}
colors.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
var depths = [Float](repeating: 1, count: width * height)
depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
func render(_ strength: Float, popOut: Float = 0, limit: Float = 0.04) -> ([UInt16], [UInt16]) {
    let command = queue.makeCommandBuffer()!
    try! reprojector.encode(color: color, depth: depth, parameters: SIMD4<Float>(strength, popOut, limit, 0.012),
                           left: left, right: right, commands: command)
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed)
    func pixels(_ texture: MTLTexture) -> [UInt16] {
        var values = [UInt16](repeating:0,count:width*height*4)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:width*8,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
        return values
    }
    return (pixels(left),pixels(right))
}
let zero = render(0), full = render(1)
precondition(zero.0 == zero.1, "Zero strength must produce identical eyes")
let center = ((height / 2) * width + width / 2) * 4
func f(_ bits: UInt16) -> Float { Float(Float16(bitPattern: bits)) }
precondition(f(full.0[center]) < f(full.1[center]), "Near geometry must have crossed disparity")
// Compare against the already device-validated Core Image video path, rather
// than merely assuming how CVPixelBuffer and Metal orient their rows.
var pixelBuffer: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
let buffer = pixelBuffer!
CVPixelBufferLockBaseAddress(buffer, [])
let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
for y in 0..<height {
    for x in 0..<width {
        let p = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        base[p] = 0; base[p+1] = UInt8(Float(y) / Float(height-1) * 255)
        base[p+2] = UInt8(Float(x) / Float(width-1) * 255); base[p+3] = 255
    }
}
CVPixelBufferUnlockBaseAddress(buffer, [])
let baseline = texture(.rgba16Float), baselineCommand = queue.makeCommandBuffer()!
let destination = CIRenderDestination(mtlTexture: baseline, commandBuffer: baselineCommand)
destination.colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
let context = CIContext(mtlDevice: device)
_ = try context.startTask(toRender: CIImage(cvPixelBuffer: buffer).oriented(.downMirrored), to: destination)
baselineCommand.commit(); baselineCommand.waitUntilCompleted()
precondition(baselineCommand.status == .completed)
var baselinePixels = [UInt16](repeating: 0, count: width * height * 4)
baselinePixels.withUnsafeMutableBytes { baseline.getBytes($0.baseAddress!, bytesPerRow: width*8, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
precondition(abs(f(zero.0[1]) - f(baselinePixels[1])) < 0.01, "Metal orientation must match the existing Core Image path")
let maximumColorError = zip(zero.0, baselinePixels).map { abs(f($0.0) - f($0.1)) }.max()!
precondition(maximumColorError < 0.02, "Zero strength must preserve the reference picture and linear color values")
precondition(full.0.allSatisfy { f($0).isFinite } && full.1.allSatisfy { f($0).isFinite })
// Mid-depth sits on the screen at balanced settings, then moves forward.
depths = [Float](repeating: 0.5, count: width * height)
depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
let balanced = render(0.6), popped = render(0.6, popOut: 1), flatPop = render(0, popOut: 1)
precondition(balanced.0 == balanced.1 && flatPop.0 == flatPop.1)
precondition(f(popped.0[center]) < f(popped.1[center]), "Pop-out must move mid-depth toward viewer")
let defaultPop = render(0.35, popOut: 0.6)
// Mid-depth moves forward, while the background stays behind the screen.
// Invert the linear output color to recover source X rather than checking a
// rendered-frame counter or merely checking that the two textures differ.
func linearToSRGB(_ value: Float) -> Float { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
let observedShift = linearToSRGB(f(defaultPop.1[center])) - linearToSRGB(f(defaultPop.0[center]))
precondition(observedShift > 0.006 && observedShift < 0.010, "Default-strength pop-out must bring mid-depth forward without translating all scenery")
let limited = render(1, popOut: 1, limit: 0.002)
precondition(abs(f(limited.0[center]) - f(limited.1[center])) < abs(f(popped.0[center]) - f(popped.1[center])), "Physical screen disparity cap must reduce the eye separation")
var layerSamples: [Float] = []
for level: Float in [0.25, 0.75] {
    depths = [Float](repeating: level, count: width * height)
    depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
    let layer = render(0.35, popOut: 1)
    layerSamples.append(linearToSRGB(f(layer.0[center])))
}
precondition(layerSamples[0] - layerSamples[1] > 0.0015, "Maximum pop-out must retain different depth layers")
// Verify depth structure from actual GPU pixels, including physical caps.
func measuredDisparity(_ result: ([UInt16], [UInt16])) -> Float {
    linearToSRGB(f(result.1[center])) - linearToSRGB(f(result.0[center]))
}
for strength: Float in [0, 0.1, 0.35, 0.6, 1] {
    for amount: Float in [0, 0.6, 1] {
        for cap: Float in [0.002, 0.03, 0.04] {
            var shifts: [Float] = []
            for level: Float in [0, 0.25, 0.5, 0.75, 1] {
                depths = [Float](repeating: level, count: width * height)
                depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
                let pair = render(strength, popOut: amount, limit: cap)
                if strength == 0 { precondition(pair.0 == pair.1, "Zero strength must remain flat at every pop-out setting") }
                shifts.append(measuredDisparity(pair))
            }
            precondition(shifts.min()! >= -0.0125 && shifts.max()! <= cap + 0.0005, "Both physical disparity limits must hold")
            precondition(zip(shifts, shifts.dropFirst()).allSatisfy { $0 <= $1 + 0.0005 }, "Depth ordering must be monotonic at all strengths and caps")
            if strength == 0.35 && amount == 0.6 && cap == 0.04 {
                precondition(shifts[1] < -0.003 && shifts[3] > 0.018, "Distant scenery must stay behind while the subject comes forward")
                precondition(shifts[3] - shifts[1] > 0.023, "Default foreground/background relief must exceed the old 0.42% span")
                precondition(shifts[4] - shifts[3] > 0.003, "Near layers must retain shape rather than collapse onto a plane")
            }
        }
    }
}
// A foreground rectangle exposes holes on opposite sides in the two eyes.
// They must use nearby blue background, not stretched red foreground.
let edgeA = width * 2 / 5, edgeB = width * 3 / 5
for y in 0..<height {
    for x in 0..<width {
        let foreground = x >= edgeA && x < edgeB
        let i = y * width + x, p = i * 4
        depths[i] = foreground ? 1 : 0
        colors[p] = foreground ? 1 : 0; colors[p+1] = foreground ? 0 : Float(x) / Float(width - 1)
        colors[p+2] = foreground ? 0 : 1; colors[p+3] = 1
    }
}
depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
colors.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
// The bounded warp deliberately trades some local relief for continuity.
// The foreground still moves toward the viewer, but no hidden background is
// invented and no foreground/background jump is allowed in source coordinates.
for amount: Float in [0, 0.6, 1] {
    let edges = render(1, popOut: amount)
    for pixels in [edges.0, edges.1] {
        precondition(pixels.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { f($0.element) == 1 },
                     "The forward surface must cover every pixel without holes")
        let row = height / 2
        let red = (0..<width).map { f(pixels[(row * width + $0) * 4]) > 0.5 }
        let transitions = zip(red, red.dropFirst()).filter { $0 != $1 }.count
        precondition(transitions == 2, "The rectangle must retain exactly two continuous edges")
        precondition(f(pixels[(row * width + width / 2) * 4]) > 0.99, "Foreground interior must remain intact")
    }
}
let smoothing = try device.makeComputePipelineState(function: library.makeFunction(name: "stabilizeDepth")!)
let smooth = texture(.r16Float)
let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(smoothing)
encoder.setTexture(depth, index: 0); encoder.setTexture(depth, index: 1); encoder.setTexture(smooth, index: 2)
var smoothingParams = SIMD4<Float>(0,1,1,0)
encoder.setBytes(&smoothingParams,length:16,index:0)
encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
precondition(command.status == .completed)
var smoothPixels = [UInt16](repeating:0,count:width*height)
smoothPixels.withUnsafeMutableBytes { smooth.getBytes($0.baseAddress!,bytesPerRow:width*2,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
precondition(f(smoothPixels[height/2*width+edgeA]) > 0.95 && f(smoothPixels[height/2*width+edgeA-1]) < 0.05, "Depth smoothing must preserve sharp silhouettes")
print("PASS: identity, eye direction, orientation/color, pop-out, disparity cap, full coverage, continuous silhouettes and edge-preserving depth")

// A half-plane silhouette remains a single transition even when the lower-
// resolution depth ramp is displaced from the color edge. Bright/dark islands
// along this diagonal caused the previous inverse warp to shimmer in a window.
var contourFailures: [String] = []
var contourCases = 0
var worstContourFall: Float = 0
for direction: Float in [-1, 1] {
    for softness: Float in [2, 4, 8, 16] {
        for mismatch: Float in [-4, 0, 4] {
            for y in 0..<height { for x in 0..<width {
                let boundary = Float(width) / 2 + Float(y - height / 2) * 0.63
                let distance = direction * (Float(x) - boundary)
                let foreground = distance >= 0, i = y * width + x, p = i * 4
                depths[i] = max(0, min(1, 0.5 + (distance + mismatch) / softness))
                colors[p] = foreground ? 1 : 0
                colors[p + 1] = Float(x) / Float(width - 1)
                colors[p + 2] = foreground ? 0 : 1; colors[p + 3] = 1
            }}
            depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            colors.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
            for (strength, amount): (Float, Float) in [(0, 1), (0.0001, 1), (0.35, 0), (0.35, 0.6), (0.35, 1), (0.6, 1)] {
                for cap: Float in [0.002, 0.03, 0.04] {
                    let pair = render(strength, popOut: amount, limit: cap)
                    for (eye, pixels) in [pair.0, pair.1].enumerated() {
                        var maximumFall: Float = 0
                        for y in 8..<(height - 8) { for x in (width / 3 + 1)..<(width * 2 / 3) {
                            let i = (y * width + x) * 4
                            maximumFall = max(maximumFall, direction * (f(pixels[i - 4]) - f(pixels[i])))
                        }}
                        contourCases += 1; worstContourFall = max(worstContourFall, maximumFall)
                        if maximumFall > 0.03 {
                            contourFailures.append("dir=\(direction), soft=\(softness), mismatch=\(mismatch), strength=\(strength), pop=\(amount), cap=\(cap), eye=\(eye), reverse=\(maximumFall)")
                        }
                    }
                }
            }
        }
    }
}
for failure in contourFailures { print("CONTOUR FAIL: \(failure)") }
print("Contour cases: \(contourCases), failures: \(contourFailures.count), worst reverse contrast: \(worstContourFall)")
fflush(stdout)
precondition(contourFailures.isEmpty, "A single silhouette must not break into alternating foreground/background islands")
print("PASS: diagonal contours, both edge directions, depth/color offsets, weak/default/high relief and screen caps")

// Verify the regularizer's contract with high-frequency, diagonally varying
// depth. This is the actual Metal kernel used before mesh construction.
let forwardRegularizer = try device.makeComputePipelineState(function: library.makeFunction(name: "regularizeDisparityForward")!)
let regularizer = try device.makeComputePipelineState(function: library.makeFunction(name: "regularizeDisparity")!)
let field = texture(.r32Float), scratch = texture(.rg32Float)
for y in 0..<height { for x in 0..<width {
    depths[y * width + x] = Float((x * 13 + y * 29 + (x / 7) * 53) % 101) / 100
}}
depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
    withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
var maximumSlope: Float = 0
for strength: Float in [0, 0.0001, 0.35, 0.6, 1] {
    for amount: Float in [0, 0.6, 1] {
        let command = queue.makeCommandBuffer()!
        for stage in [forwardRegularizer, regularizer] {
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(stage)
            encoder.setTexture(depth, index: 0); encoder.setTexture(scratch, index: 1); encoder.setTexture(field, index: 2)
            var params = SIMD4<Float>(strength, amount, 0.04, 0.012)
            encoder.setBytes(&params, length: 16, index: 0)
            encoder.dispatchThreads(MTLSize(width: height, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            encoder.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { field.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        precondition(values.allSatisfy { $0.isFinite && $0 >= -0.006001 && $0 <= 0.020001 })
        if strength == 0 { precondition(values.allSatisfy { $0 == 0 }) }
        for y in 0..<height {
            precondition(values[y * width] == 0 && values[(y + 1) * width - 1] == 0,
                         "Both horizontal endpoints must stay fixed")
            for x in 1..<width {
                let slope = abs(values[y * width + x] - values[y * width + x - 1]) * Float(width - 1)
                maximumSlope = max(maximumSlope, slope)
                precondition(slope <= 0.45001, "Both eyes must retain a positive, bounded horizontal Jacobian")
            }
        }
    }
}
let held = render(0.35, popOut: 0.6)
_ = render(0.6, popOut: 1)
let restored = render(0.35, popOut: 0.6)
precondition(held.0 == restored.0 && held.1 == restored.1,
             "Restoring settings with a frozen source must reproduce identical eye pixels")
print("PASS: 15 adversarial disparity fields, zero identity, caps, fixed endpoints, repeatability; maximum slope: \(maximumSlope)")
