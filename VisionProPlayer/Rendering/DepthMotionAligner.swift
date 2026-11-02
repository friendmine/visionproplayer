import Metal

/// Low-resolution bidirectional patch matching. Only depth is transported;
/// displayed color always comes from the current decoded video frame.
final class DepthMotionAligner {
    private let device: MTLDevice
    private let match: MTLComputePipelineState
    private let warp: MTLComputePipelineState
    private var backward: MTLTexture?
    private var forward: MTLTexture?
    private var output: MTLTexture?
    // Read back by GPU regression tests after command completion.
    var diagnosticMotion: MTLTexture? { backward }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let match = library.makeFunction(name: "matchDepthMotion"),
              let warp = library.makeFunction(name: "warpMotionDepth") else { throw StereoReprojector.Failure.unavailable }
        self.match = try device.makeComputePipelineState(function: match)
        self.warp = try device.makeComputePipelineState(function: warp)
    }

    // Sequential encoders may reuse these textures in one command buffer. The
    // caller must consume the result before the next call, and allow one GPU
    // frame in flight, as StereoRenderer already does.
    func encode(source: MTLTexture, target: MTLTexture, depth: MTLTexture,
                neutral: Float, conservative: Bool, commands: MTLCommandBuffer) throws -> MTLTexture {
        let w = max(2, (source.width + 1) / 2), h = max(2, (source.height + 1) / 2)
        if backward?.width != w || backward?.height != h {
            backward = make(.rgba16Float, w, h); forward = make(.rgba16Float, w, h)
        }
        if output?.width != depth.width || output?.height != depth.height {
            output = make(.rg16Float, depth.width, depth.height)
        }
        guard let backward, let forward, let output else { throw StereoReprojector.Failure.unavailable }
        for (from, to, result) in [(source, target, backward), (target, source, forward)] {
            guard let encoder = commands.makeComputeCommandEncoder() else { throw StereoReprojector.Failure.unavailable }
            encoder.label = "Depth motion patch matching"
            encoder.setComputePipelineState(match)
            encoder.setTexture(from, index: 0); encoder.setTexture(to, index: 1); encoder.setTexture(result, index: 2)
            encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw StereoReprojector.Failure.unavailable }
        encoder.label = "Reliable depth transport"
        encoder.setComputePipelineState(warp)
        encoder.setTexture(depth, index: 0); encoder.setTexture(backward, index: 1)
        encoder.setTexture(forward, index: 2); encoder.setTexture(output, index: 3)
        var parameters = SIMD4<Float>(Float(source.width), Float(source.height), neutral, conservative ? 1 : 0)
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: depth.width, height: depth.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        return output
    }

    private func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: d)
    }
}
