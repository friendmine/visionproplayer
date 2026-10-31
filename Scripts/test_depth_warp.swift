import Foundation
import Metal
import CoreImage
import CoreVideo

// Numerical GPU test independent of the neural model and of stereo perception.
let device = MTLCreateSystemDefaultDevice()!
let source = try String(contentsOfFile: "VisionProPlayer/Rendering/DepthStereo.metal", encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "synthesizeStereo")!)
let queue = device.makeCommandQueue()!
let width = 1024, height = 64
func texture(_ format: MTLPixelFormat) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
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
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (i,t) in [color,depth,left,right].enumerated() { encoder.setTexture(t,index:i) }
    var value = SIMD4<Float>(strength, popOut, limit, 0.012)
    encoder.setBytes(&value,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
    encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1), threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
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
// At mid-depth the intended two-eye shift is 2.148% of width at this setting.
// Invert the linear output color to recover source X rather than checking a
// rendered-frame counter or merely checking that the two textures differ.
func linearToSRGB(_ value: Float) -> Float { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
let observedShift = linearToSRGB(f(defaultPop.1[center])) - linearToSRGB(f(defaultPop.0[center]))
precondition(observedShift > 0.020 && observedShift < 0.024, "Default-strength pop-out must produce a meaningful forward offset")
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
// A foreground rectangle exposes holes on opposite sides in the two eyes.
// They must use nearby blue background, not stretched red foreground.
let edgeA = width * 2 / 5, edgeB = width * 3 / 5
for y in 0..<height {
    for x in 0..<width {
        let foreground = x >= edgeA && x < edgeB
        let i = y * width + x, p = i * 4
        depths[i] = foreground ? 1 : 0
        colors[p] = foreground ? 1 : 0; colors[p+1] = 0
        colors[p+2] = foreground ? 0 : 1; colors[p+3] = 1
    }
}
depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
colors.withUnsafeBytes { color.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
let a = ((height / 2) * width + edgeA) * 4, b = ((height / 2) * width + edgeB) * 4
// The holes/overlaps move with the stereo convergence offset. Check their
// centers at the analytically expected positions, not the old source edges.
for (amount, shift): (Float, Float) in [(0, 0), (0.6, 0.0084), (1, 0.014)] {
    let edges = render(1, popOut: amount)
    let offset = Int((shift * Float(width)).rounded()) * 4
    precondition(f(edges.0[a+offset+2]) > 0.9 && f(edges.1[b-offset+2]) > 0.9, "Disocclusions must fill from background")
    precondition(f(edges.0[b+offset]) > 0.9 && f(edges.1[a-offset]) > 0.9, "Foreground must win overlapping projections")
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
print("PASS: identity, eye direction, orientation/color, pop-out, disparity cap, background gap fill, foreground occlusion and edge-preserving depth")
