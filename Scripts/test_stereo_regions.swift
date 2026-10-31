import Foundation
import CoreImage
import CoreVideo
import Metal

@main struct StereoRegionChecks {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let context = CIContext(mtlDevice: device)
        for layout in [StereoLayout.fullOU, .halfOU, .fullSBS, .halfSBS, .flat] {
            let w = 32, h = 24
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let p = y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4
                let firstEye = layout.isTopBottom ? y < h/2 : x < w/2
                bytes[p] = firstEye ? 0 : 255
                bytes[p+1] = UInt8(y * 6)
                bytes[p+2] = firstEye ? 255 : 0
                bytes[p+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.downMirrored)
            let regions = layout.eyeRegions(width: w, height: h)
            var eyes: [[UInt16]] = []
            for region in [regions.left, regions.right] {
                let width = Int(region.width), height = Int(region.height)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
                let texture = device.makeTexture(descriptor: descriptor)!, command = queue.makeCommandBuffer()!
                let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
                destination.colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
                let crop = image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                _ = try context.startTask(toRender: crop, to: destination)
                command.commit(); command.waitUntilCompleted(); precondition(command.status == .completed)
                var pixels = [UInt16](repeating: 0, count: width * height * 4)
                pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width*8, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
                eyes.append(pixels)
            }
            func f(_ eye: Int, _ i: Int) -> Float { Float(Float16(bitPattern: eyes[eye][i])) }
            precondition(f(0,0) > 0.9 && f(0,2) < 0.01, "Left eye must contain source top/left, not bottom/right")
            if layout.isStereo { precondition(f(1,2) > 0.9 && f(1,0) < 0.01, "Right eye must contain source bottom/right") }
            else { precondition(eyes[0] == eyes[1]) }
            let lastRow = (Int(regions.left.height)-1) * Int(regions.left.width) * 4
            precondition(f(0,1) < f(0,lastRow+1), "Source rows must remain upright")
            print("PASS: \(layout.rawValue) GPU crop, eye order and vertical orientation")
        }
    }
}
