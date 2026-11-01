import Metal

/// Forward-project a continuous depth surface with antialiased coverage.
/// A bounded warp prevents foldovers at uncertain contours.
/// Kept independent of RealityKit so the same encoder is exercised by GPU tests.
final class StereoReprojector {
    private let device: MTLDevice
    private let forward: MTLComputePipelineState
    private let regularize: MTLComputePipelineState
    private var field: MTLTexture?
    private var scratch: MTLTexture?
    private let pipeline: MTLRenderPipelineState
    private var multisampleColor: MTLTexture?

    enum Failure: Error { case unavailable }

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard device.supportsTextureSampleCount(4),
              let forwardFunction = library.makeFunction(name: "regularizeDisparityForward"),
              let regularizeFunction = library.makeFunction(name: "regularizeDisparity"),
              let vertex = library.makeFunction(name: "projectStereoVertex"),
              let fragment = library.makeFunction(name: "projectStereoFragment") else { throw Failure.unavailable }
        forward = try device.makeComputePipelineState(function: forwardFunction)
        regularize = try device.makeComputePipelineState(function: regularizeFunction)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = 4
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func encode(color: MTLTexture, depth: MTLTexture, parameters: SIMD4<Float>,
                left: MTLTexture, right: MTLTexture, commands: MTLCommandBuffer) throws {
        if multisampleColor?.width != left.width || multisampleColor?.height != left.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: left.width, height: left.height, mipmapped: false)
            descriptor.textureType = .type2DMultisample; descriptor.sampleCount = 4
            #if os(visionOS)
            descriptor.storageMode = .memoryless
            #else
            descriptor.storageMode = .private
            #endif
            descriptor.usage = .renderTarget
            multisampleColor = device.makeTexture(descriptor: descriptor)
        }
        guard let multisampleColor else { throw Failure.unavailable }
        // Two-pixel cells retain substantially more detail than the model grid,
        // while bounding geometry cost independently of the original video size.
        let columns = (left.width + 1) / 2, rows = (left.height + 1) / 2
        if field?.width != columns + 1 || field?.height != rows + 1 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
                width: columns + 1, height: rows + 1, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            field = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .rg32Float
            scratch = device.makeTexture(descriptor: descriptor)
        }
        guard let field, let scratch else { throw Failure.unavailable }
        // End the first encoder before reading its scratch texture. This uses
        // Metal's tracked-resource dependency rather than in-invocation reads
        // of a texture that was just written.
        for stage in [forward, regularize] {
            guard let compute = commands.makeComputeCommandEncoder() else { throw Failure.unavailable }
            compute.label = "AI bounded disparity field"
            compute.setComputePipelineState(stage)
            compute.setTexture(depth, index: 0); compute.setTexture(scratch, index: 1); compute.setTexture(field, index: 2)
            var params = parameters
            compute.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            compute.dispatchThreads(MTLSize(width: rows + 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            compute.endEncoding()
        }
        for (destination, eye): (MTLTexture, Float) in [(left, 1), (right, -1)] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = multisampleColor
            pass.colorAttachments[0].resolveTexture = destination
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailable }
            encoder.label = eye > 0 ? "AI forward projection left" : "AI forward projection right"
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            var grid = SIMD4<Float>(Float(columns), Float(rows), eye, 0)
            encoder.setVertexBytes(&grid, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setVertexTexture(field, index: 0)
            encoder.setFragmentTexture(color, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: columns * rows * 6)
            encoder.endEncoding()
        }
    }
}
