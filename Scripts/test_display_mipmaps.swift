import Foundation
import Metal

// A subpixel checkerboard must become its area average during minification,
// without changing the full-resolution image or mixing the two eyes.
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let width = 128, height = 72
var textures: [MTLTexture] = []
var originals: [[UInt16]] = []
for eye in 0..<2 {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: true)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = device.makeTexture(descriptor: descriptor)!
    var values = [UInt16](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let p = (y * width + x) * 4, even = (x + y) % 2 == 0
            if eye == 0 { values[p + (even ? 0 : 2)] = Float16(1).bitPattern }
            else if even { values[p + 1] = Float16(1).bitPattern }
            values[p + 3] = Float16(1).bitPattern
        }
    }
    values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
    textures.append(texture); originals.append(values)
}
let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
for texture in textures { blit.generateMipmaps(for: texture) }
blit.endEncoding(); command.commit(); command.waitUntilCompleted()
precondition(command.status == .completed)
for (eye, texture) in textures.enumerated() {
    let expected: [Float] = eye == 0 ? [0.5, 0, 0.5, 1] : [0, 0.5, 0, 1]
    for level in 0..<texture.mipmapLevelCount {
        let w = max(1, width >> level), h = max(1, height >> level)
        var pixels = [UInt16](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 8,
            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level) }
        if level == 0 { precondition(pixels == originals[eye], "Base image must remain unchanged") }
        else {
            for (i, value) in pixels.enumerated() {
                precondition(abs(Float(Float16(bitPattern: value)) - expected[i % 4]) < 0.002,
                    "Lower levels must average fine detail without changing eye identity, brightness or alpha")
            }
        }
    }
}
print("PASS: minified checkerboard averages, unchanged full-resolution image, separate eyes, all mip levels initialized")
