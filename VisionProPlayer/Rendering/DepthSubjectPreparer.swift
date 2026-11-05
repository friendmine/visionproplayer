import Metal

final class DepthSubjectPreparer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var output: MTLTexture?
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let function = library.makeFunction(name: "prepareSubjectDepth") else { throw StereoReprojector.Failure.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func encode(raw: MTLTexture, crop: SIMD4<Float>, lower: Float, upper: Float, commands: MTLCommandBuffer) throws -> MTLTexture {
        if output?.width != raw.width || output?.height != raw.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: raw.width, height: raw.height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
            output = device.makeTexture(descriptor: d)
        }
        guard let output, let encoder = commands.makeComputeCommandEncoder() else { throw StereoReprojector.Failure.unavailable }
        encoder.label = "Aspect-aware foreground depth"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(raw, index: 0); encoder.setTexture(output, index: 1)
        var crop = crop, range = SIMD2<Float>(lower, 1 / max(0.0001, upper - lower))
        encoder.setBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&range, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: raw.width, height: raw.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        return output
    }
}
