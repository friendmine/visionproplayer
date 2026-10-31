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
let width = 256, height = 64
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
func render(_ strength: Float) -> ([UInt16], [UInt16]) {
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (i,t) in [color,depth,left,right].enumerated() { encoder.setTexture(t,index:i) }
    var value = strength
    encoder.setBytes(&value,length:4,index:0)
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
print("PASS: zero-strength identity, near-depth eye direction, vertical orientation, finite border samples")
