import Metal

/// Current-frame color guidance improves depth sampling at visible contours.
/// No previous RGB, generated background, or person-shape prior is introduced.
final class DepthEdgeRefiner {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let guidePipeline: MTLComputePipelineState
    private var output: MTLTexture?
    private var guide: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let function = library.makeFunction(name: "refineDepthEdges"),
              let makeGuide = library.makeFunction(name: "makeDepthEdgeGuide") else { throw StereoReprojector.Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        guidePipeline = try device.makeComputePipelineState(function: makeGuide)
    }

    func encode(color: MTLTexture, depth: MTLTexture, hasConfidence: Bool,
                commands: MTLCommandBuffer) throws -> MTLTexture {
        // Preserve color-pixel contour positions before the bounded projection.
        // Input color is already capped at 1920 pixels on the longest side.
        let width = color.width, height = color.height
        if output?.width != width || output?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
            output = device.makeTexture(descriptor: d)
        }
        if guide?.width != depth.width || guide?.height != depth.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: depth.width, height: depth.height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
            guide = device.makeTexture(descriptor: d)
        }
        guard let output, let guide, let makeGuide = commands.makeComputeCommandEncoder() else { throw StereoReprojector.Failure.unavailable }
        // Calculate perceptual features once per depth texel, not 16 times per
        // display pixel. Both encoders share the frame's tracked dependencies.
        makeGuide.label = "Depth contour color guide"
        makeGuide.setComputePipelineState(guidePipeline)
        makeGuide.setTexture(color, index: 0); makeGuide.setTexture(guide, index: 1)
        makeGuide.dispatchThreads(MTLSize(width: guide.width, height: guide.height, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        makeGuide.endEncoding()
        guard let encoder = commands.makeComputeCommandEncoder() else { throw StereoReprojector.Failure.unavailable }
        encoder.label = "Current-frame depth edge refinement"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(color, index: 0); encoder.setTexture(depth, index: 1); encoder.setTexture(output, index: 2)
        encoder.setTexture(guide, index: 3)
        var confidence: UInt32 = hasConfidence ? 1 : 0
        encoder.setBytes(&confidence, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        return output
    }
}
