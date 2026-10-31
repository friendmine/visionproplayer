@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Metal
@preconcurrency import RealityKit
import SwiftUI

/// Two SDR GPU textures are sampled through RealityKit's per-eye camera switch.
/// A single decoded packed frame supplies both eyes so their timestamps always match.
private final class RetainedVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

@MainActor
final class StereoRenderer {
    let entity = ModelEntity()
    private var material: ShaderGraphMaterial?
    private var eyeCheckMaterial: ShaderGraphMaterial?
    private var eyeCheck = false
    private var leftSurface: LowLevelTexture?
    private var rightSurface: LowLevelTexture?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var dimensions = SIMD2<Int>(0, 0)
    private var inFlight = false
    private(set) var failure: String?
    private var textureSwap: Bool?
    private let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private var leftTexture: TextureResource?
    private var rightTexture: TextureResource?

    func prepare() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        commandQueue = queue
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        material = try await ShaderGraphMaterial(named: "/Root/StereoMaterial", from: "StereoMaterial.usda")
        eyeCheckMaterial = try await ShaderGraphMaterial(named: "/Root/EyeCheckMaterial", from: "StereoMaterial.usda")
        entity.model = ModelComponent(mesh: .generatePlane(width: 1, height: 1), materials: [])
    }

    func fit(in size: SIMD3<Float>, aspect: Float) {
        let width = min(abs(size.x), abs(size.y) * aspect)
        entity.scale = [max(0.01, width), max(0.01, width / aspect), 1]
    }

    private func makeTexture(width: Int, height: Int) throws -> (TextureResource, LowLevelTexture) {
        let surface = try LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float,
            width: width, height: height, textureUsage: [.shaderRead, .renderTarget, .shaderWrite]))
        return (try TextureResource(from: surface), surface)
    }

    func bindEyes(swapped: Bool) throws {
        guard textureSwap != swapped, var material, let leftTexture, let rightTexture else { return }
        try material.setParameter(name: "LeftTexture", value: .textureResource(swapped ? rightTexture : leftTexture))
        try material.setParameter(name: "RightTexture", value: .textureResource(swapped ? leftTexture : rightTexture))
        self.material = material
        if !eyeCheck { entity.model?.materials = [material] }
        textureSwap = swapped
    }

    func setEyeCheck(_ enabled: Bool) {
        guard eyeCheck != enabled else { return }
        eyeCheck = enabled
        if let selected = enabled ? eyeCheckMaterial : material {
            entity.model?.materials = [selected]
        }
    }

    /// Returns false when a previous GPU frame is still in flight; caller drops rather than queues frames.
    func render(_ buffer: CVPixelBuffer, swapped: Bool) throws -> Bool {
        guard !inFlight, let context = ciContext, let commandQueue else { return false }
        let packedWidth = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard packedWidth >= 2, packedWidth.isMultiple(of: 2), height > 0 else { throw RenderError.invalidFrame }
        let width = packedWidth / 2
        if dimensions != SIMD2(width, height) {
            (leftTexture, leftSurface) = try makeTexture(width: width, height: height)
            (rightTexture, rightSurface) = try makeTexture(width: width, height: height)
            dimensions = SIMD2(width, height)
            textureSwap = nil
        }
        if textureSwap != swapped { try bindEyes(swapped: swapped) }
        guard let leftSurface, let rightSurface, let commands = commandQueue.makeCommandBuffer() else { return false }
        let left = leftSurface.replace(using: commands)
        let right = rightSurface.replace(using: commands)
        let image = CIImage(cvPixelBuffer: buffer).oriented(.downMirrored)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let leftImage = image.cropped(to: bounds)
        let rightImage = image.cropped(to: CGRect(x: width, y: 0, width: width, height: height))
            .transformed(by: CGAffineTransform(translationX: -CGFloat(width), y: 0))
        let leftDestination = CIRenderDestination(mtlTexture: left, commandBuffer: commands)
        let rightDestination = CIRenderDestination(mtlTexture: right, commandBuffer: commands)
        leftDestination.colorSpace = colorSpace
        rightDestination.colorSpace = colorSpace
        _ = try context.startTask(toRender: leftImage, to: leftDestination)
        _ = try context.startTask(toRender: rightImage, to: rightDestination)
        inFlight = true
        let retained = RetainedVideoFrame(buffer)
        commands.addCompletedHandler { [weak self, retained] command in
            // Retain source pixels until Core Image has finished reading them.
            _ = retained.buffer
            let failure = command.status == .error ? (command.error?.localizedDescription ?? "GPU 视频纹理更新失败") : nil
            Task { @MainActor [weak self] in
                self?.failure = failure
                self?.inFlight = false
            }
        }
        commands.commit()
        return true
    }

    enum RenderError: LocalizedError {
        case unavailable, invalidFrame
        var errorDescription: String? {
            switch self {
            case .unavailable: "设备无法创建 Metal 渲染器。"
            case .invalidFrame: "SBS 需要偶数宽度的左右拼接视频。"
            }
        }
    }
}

struct StereoPlayerView: View {
    let model: PlayerModel
    let request: PlaybackRequest
    @State private var renderer = StereoRenderer()
    @State private var aspect: Float = 16 / 9
    @State private var ready = false

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                do {
                    try await renderer.prepare()
                    content.add(renderer.entity)
                    let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                    renderer.entity.position = bounds.center
                    renderer.fit(in: bounds.extents, aspect: aspect)
                    renderer.setEyeCheck(model.eyeCheck)
                    ready = true
                } catch {
                    model.rendererError = error.localizedDescription
                }
            } update: { content in
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                renderer.entity.position = bounds.center
                renderer.fit(in: bounds.extents, aspect: aspect)
                do { try renderer.bindEyes(swapped: model.swapEyes) }
                catch { model.rendererError = error.localizedDescription }
                renderer.setEyeCheck(model.eyeCheck)
            }
            .frame(width: CGFloat(geometry.size.width), height: CGFloat(geometry.size.height))
            .frame(depth: 0)
        }
        // Keep the screen on the window plane; the default 3D depth otherwise
        // moves it toward the viewer and can magnify it over the transport controls.
        .frame(depth: 0)
        .task(id: ready) {
            guard ready else { return }
            while !Task.isCancelled, model.request?.id == request.id {
                if let failure = renderer.failure { model.rendererError = failure; return }
                if let buffer = model.copyVideoFrame() {
                    do {
                        if try renderer.render(buffer, swapped: model.swapEyes) {
                            let width = CVPixelBufferGetWidth(buffer)
                            let height = CVPixelBufferGetHeight(buffer)
                            aspect = request.layout.displayAspect(width: width, height: height)
                            model.frameSize = "\(width) × \(height) → 左右眼各 \(width / 2) × \(height)"
                            model.renderedFrames += 1
                        }
                    } catch {
                        model.rendererError = error.localizedDescription
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
