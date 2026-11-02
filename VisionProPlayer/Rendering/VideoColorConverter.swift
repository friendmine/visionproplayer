import CoreImage
import CoreVideo
import Metal

/// Use the decoded frame's color attachments, just like the flat video path.
/// Raw BGRA values are not necessarily sRGB (native video commonly carries
/// Rec.709). Interpreting them as sRGB only during stereo causes brightness
/// jumps whenever inference falls back to a flat frame.
final class VideoColorConverter {
    private let device: MTLDevice
    private var texture: MTLTexture?
    init(device: MTLDevice) { self.device = device }

    func encode(_ buffer: CVPixelBuffer, width: Int, height: Int, scale: Double,
                context: CIContext, commands: MTLCommandBuffer) throws -> MTLTexture {
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture else { throw StereoReprojector.Failure.unavailable }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let image = CIImage(cvPixelBuffer: buffer).oriented(.downMirrored)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        _ = try context.startTask(toRender: image, to: destination)
        return texture
    }
}
