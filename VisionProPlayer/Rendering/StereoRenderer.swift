@preconcurrency import CoreImage
@preconcurrency import CoreVideo
@preconcurrency import Metal
@preconcurrency import RealityKit
import SwiftUI

/// Two SDR GPU textures are sampled through RealityKit's per-eye camera switch.
/// A single decoded packed frame supplies both eyes so their timestamps always match.
private final class RetainedVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let textureReference: CVMetalTexture?
    init(_ buffer: CVPixelBuffer, textureReference: CVMetalTexture? = nil) {
        self.buffer = buffer; self.textureReference = textureReference
    }
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
    private var videoColorConverter: VideoColorConverter?
    private var dimensions = SIMD2<Int>(0, 0)
    private var inFlight = false
    private(set) var failure: String?
    private var textureSwap: Bool?
    private let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private var leftTexture: TextureResource?
    private var rightTexture: TextureResource?
    private var textureCache: CVMetalTextureCache?
    private var depthPipeline: MTLComputePipelineState?
    private var motionDepthPipeline: MTLComputePipelineState?
    private var motionAligner: DepthMotionAligner?
    private var edgeRefiner: DepthEdgeRefiner?
    private var subjectPreparer: DepthSubjectPreparer?
    private var depthGuideConverters: [VideoColorConverter] = []
    private var depthGuides: [MTLTexture?] = [nil, nil]
    private var currentGuideConverter: VideoColorConverter?
    private var motionEnabled: Bool?
    private(set) var lastGPUMilliseconds: Double = 0
    private var reprojector: StereoReprojector?
    private var depthHistory: [MTLTexture] = []
    private var depthIndex = 0
    private var depthHistoryValid = false
    private var processedDepthBuffer: CVPixelBuffer?
    private var debugCaptured = false
    var canRender: Bool { !inFlight }

    func prepare() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        commandQueue = queue
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        if let library = device.makeDefaultLibrary(),
           let stabilize = library.makeFunction(name: "stabilizeDepth") {
            depthPipeline = try await device.makeComputePipelineState(function: stabilize)
            reprojector = try StereoReprojector(device: device, library: library)
            motionAligner = try DepthMotionAligner(device: device, library: library)
            edgeRefiner = try DepthEdgeRefiner(device: device, library: library)
            subjectPreparer = try DepthSubjectPreparer(device: device, library: library)
            if let filter = library.makeFunction(name: "stabilizeMotionDepth") {
                motionDepthPipeline = try await device.makeComputePipelineState(function: filter)
            }
        }
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        videoColorConverter = VideoColorConverter(device: device)
        depthGuideConverters = (0..<2).map { _ in VideoColorConverter(device: device) }
        currentGuideConverter = VideoColorConverter(device: device)
        material = try await ShaderGraphMaterial(named: "/Root/StereoMaterial", from: "StereoMaterial.usda")
        eyeCheckMaterial = try await ShaderGraphMaterial(named: "/Root/EyeCheckMaterial", from: "StereoMaterial.usda")
        entity.model = ModelComponent(mesh: .generatePlane(width: 1, height: 1), materials: [])
        entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        entity.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: 1, depth: 0.001)]))
    }

    func fit(in size: SIMD3<Float>, centeredAt center: SIMD3<Float>, aspect: Float) {
        // The SwiftUI black backing and window glass occupy the window plane.
        // Keep an explicit physical gap to prevent coplanar depth fighting,
        // including when SwiftUI updates the layout or the user resizes it.
        entity.position = center + SIMD3<Float>(0, 0, 0.005)
        let width = min(abs(size.x), abs(size.y) * aspect)
        entity.scale = [max(0.01, width), max(0.01, width / aspect), 1]
    }

    private func makeTexture(width: Int, height: Int) throws -> (TextureResource, LowLevelTexture) {
        // A high-resolution eye image needs lower-resolution levels when it
        // occupies fewer display pixels, especially at a small window or angle.
        let levels = 1 + Int(floor(log2(Double(max(width, height)))))
        let surface = try LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapLevelCount: levels,
            textureUsage: [.shaderRead, .renderTarget, .shaderWrite]))
        return (try TextureResource(from: surface), surface)
    }

    private func generateDisplayMipmaps(_ left: MTLTexture, _ right: MTLTexture, using commands: MTLCommandBuffer) throws {
        guard let blit = commands.makeBlitCommandEncoder() else { throw RenderError.unavailable }
        // Both eyes and all mip levels publish in the same command buffer.
        blit.generateMipmaps(for: left)
        blit.generateMipmaps(for: right)
        blit.endEncoding()
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
    func render(_ buffer: CVPixelBuffer, swapped: Bool, layout: StereoLayout = .flat, coverageScale: Float = 1) throws -> Bool {
        guard !inFlight, let context = ciContext, let commandQueue else { return false }
        let packedWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard packedWidth >= 2, sourceHeight >= 2,
              (!layout.isStereo || (layout.isTopBottom ? sourceHeight.isMultiple(of: 2) : packedWidth.isMultiple(of: 2))) else { throw RenderError.invalidFrame }
        let scale = !layout.isStereo ? min(1.0, 1920.0 / Double(max(packedWidth, sourceHeight))) : 1.0
        let regions = layout.eyeRegions(width: max(2, Int(Double(packedWidth) * scale)), height: max(2, Int(Double(sourceHeight) * scale)))
        let width = Int(regions.left.width), height = Int(regions.left.height)
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
        var image = CIImage(cvPixelBuffer: buffer).oriented(.downMirrored)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if !layout.isStereo && coverageScale > 1 {
            let zoom = CGFloat(coverageScale)
            image = image.transformed(by: CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                tx: CGFloat(width) * (1 - zoom) / 2, ty: CGFloat(height) * (1 - zoom) / 2))
        }
        let leftImage = image.cropped(to: regions.left)
        let rightImage = image.cropped(to: regions.right)
            .transformed(by: CGAffineTransform(translationX: -regions.right.minX, y: -regions.right.minY))
        let leftDestination = CIRenderDestination(mtlTexture: left, commandBuffer: commands)
        let rightDestination = CIRenderDestination(mtlTexture: right, commandBuffer: commands)
        leftDestination.colorSpace = colorSpace
        rightDestination.colorSpace = colorSpace
        _ = try context.startTask(toRender: leftImage, to: leftDestination)
        _ = try context.startTask(toRender: rightImage, to: rightDestination)
        try generateDisplayMipmaps(left, right, using: commands)
        inFlight = true
        let retained = RetainedVideoFrame(buffer)
        commands.addCompletedHandler { [weak self, retained] command in
            // Retain source pixels until Core Image has finished reading them.
            _ = retained.buffer
            let failure = command.status == .error ? (command.error?.localizedDescription ?? "GPU 视频纹理更新失败") : nil
            Task { @MainActor [weak self] in
                self?.failure = failure
                self?.lastGPUMilliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
                self?.inFlight = false
            }
        }
        commands.commit()
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture?) {
        guard let device = commandQueue?.device else { throw RenderError.unavailable }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var reference: CVMetalTexture?
        if let textureCache, CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
            format, width, height, 0, &reference) == kCVReturnSuccess,
           let reference, let texture = CVMetalTextureGetTexture(reference) {
            return (texture, reference)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw RenderError.invalidFrame }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return (texture, nil)
    }

    func disparityLimits(distance: Float?) -> SIMD2<Float> {
        let widthMeters = max(0.1, entity.scale.x)
        let front = min(0.05, distance.map { max(0.01, $0 * 0.02) } ?? 0.05)
        let rear = min(0.04, distance.map { max(0.01, $0 * 0.015) } ?? 0.04)
        return [min(distance == nil ? 0.04 : 0.03, front / widthMeters), min(0.012, rear / widthMeters)]
    }

    func renderConverted(_ buffer: CVPixelBuffer, depth: EstimatedDepth, strength: Float, popOut: Float, protectProportions: Bool, distance: Float?, swapped: Bool, disparityGain: Float = 1, alignMotion: Bool = false, refineEdges: Bool = false) throws -> Bool {
        guard !inFlight, let queue = commandQueue, let depthPipeline, let reprojector,
              let context = ciContext, let videoColorConverter else { return false }
        if motionEnabled != alignMotion {
            // Never feed one algorithm's history into the other during A/B.
            depthHistoryValid = false; processedDepthBuffer = nil
            depthGuides = [nil, nil]; motionEnabled = alignMotion
        }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        let scale = min(1.0, 1920.0 / Double(max(sourceWidth, sourceHeight)))
        let width = max(2, Int(Double(sourceWidth) * scale)), height = max(2, Int(Double(sourceHeight) * scale))
        if dimensions != SIMD2(width, height) {
            (leftTexture, leftSurface) = try makeTexture(width: width, height: height)
            (rightTexture, rightSurface) = try makeTexture(width: width, height: height)
            dimensions = SIMD2(width, height); textureSwap = nil
        }
        if textureSwap != swapped { try bindEyes(swapped: swapped) }
        let dw = CVPixelBufferGetWidth(depth.buffer), dh = CVPixelBufferGetHeight(depth.buffer)
        if depthHistory.first?.width != dw || depthHistory.first?.height != dh {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: dw, height: dh, mipmapped: false)
            desc.storageMode = .private; desc.usage = [.shaderRead, .shaderWrite]
            depthHistory = (0..<2).compactMap { _ in queue.device.makeTexture(descriptor: desc) }
            depthHistoryValid = false
        }
        guard depthHistory.count == 2, let leftSurface, let rightSurface,
              let commands = queue.makeCommandBuffer() else { throw RenderError.unavailable }
        let color = try videoColorConverter.encode(buffer, width: width, height: height, scale: scale,
                                                   context: context, commands: commands)
        let depthFormat: MTLPixelFormat = CVPixelBufferGetPixelFormatType(depth.buffer) == kCVPixelFormatType_OneComponent16Half ? .r16Float : .r32Float
        let raw = try texture(depth.buffer, format: depthFormat)
        // Reuse the same stabilized depth for a frozen source. Changing only
        // the protection switch must not perform another temporal blend and
        // silently change the depth used for the comparison.
        let updatesDepth = !depthHistoryValid || processedDepthBuffer !== depth.buffer
        let nextDepthIndex = updatesDepth ? 1 - depthIndex : depthIndex
        let smooth = depthHistory[nextDepthIndex]
        let guideScale = 128.0 / Double(max(sourceWidth, sourceHeight))
        let guideWidth = max(2, Int(Double(sourceWidth) * guideScale))
        let guideHeight = max(2, Int(Double(sourceHeight) * guideScale))
        if updatesDepth {
            var previous = depthHistory[depthIndex]
            var filter = depthPipeline
            if alignMotion {
                guard let motionAligner, let motionDepthPipeline else { throw RenderError.unavailable }
                let guide = try depthGuideConverters[nextDepthIndex].encode(depth.source, width: guideWidth, height: guideHeight,
                    scale: guideScale, context: context, commands: commands)
                if depthHistoryValid, !depth.resetHistory, let oldGuide = depthGuides[depthIndex] {
                    previous = try motionAligner.encode(source: oldGuide, target: guide, depth: previous,
                        neutral: 0.5, conservative: false, commands: commands)
                }
                depthGuides[nextDepthIndex] = guide
                filter = motionDepthPipeline
            }
            var inputDepth = raw.0
            var normalization = SIMD2<Float>(depth.lower, 1 / (depth.upper - depth.lower))
            if depth.subjectAccuracy {
                guard let subjectPreparer else { throw RenderError.unavailable }
                inputDepth = try subjectPreparer.encode(raw: raw.0, crop: depth.contentRegion, lower: depth.lower, upper: depth.upper, commands: commands)
                normalization = SIMD2(0, 1)
            }
            guard let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.unavailable }
            var params = SIMD4<Float>(normalization.x, normalization.y, (!depthHistoryValid || depth.resetHistory) ? 1 : 0, 0)
            encoder.setComputePipelineState(filter)
            encoder.setTexture(inputDepth, index: 0); encoder.setTexture(previous, index: 1); encoder.setTexture(smooth, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: dw, height: dh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
        }
        let left = leftSurface.replace(using: commands), right = rightSurface.replace(using: commands)
        // Bound physical disparity as screens grow. In cinema also cap its
        // angular extent using the configured viewing distance (not head tracking).
        let limits = disparityLimits(distance: distance)
        let warpParams = SIMD4<Float>(max(0, min(1, strength)), max(0, min(1, popOut)),
                                     limits.x, limits.y)
        var displayedDepth = smooth
        if alignMotion {
            guard let motionAligner, let currentGuideConverter, let sourceGuide = depthGuides[nextDepthIndex] else { throw RenderError.unavailable }
            let guide = try currentGuideConverter.encode(buffer, width: guideWidth, height: guideHeight,
                scale: guideScale, context: context, commands: commands)
            displayedDepth = try motionAligner.encode(source: sourceGuide, target: guide, depth: smooth,
                neutral: 0.5 - 0.15 * warpParams.y, conservative: true, commands: commands)
        }
        if refineEdges {
            guard let edgeRefiner else { throw RenderError.unavailable }
            displayedDepth = try edgeRefiner.encode(color: color, depth: displayedDepth, hasConfidence: alignMotion, commands: commands)
        }
        try reprojector.encode(color: color, depth: displayedDepth, parameters: warpParams, protectProportions: protectProportions, sourceIsLinear: true, disparityGain: disparityGain, preserveDepthPlanes: depth.subjectAccuracy,
                               left: left, right: right, commands: commands)
        try generateDisplayMipmaps(left, right, using: commands)
        depthIndex = nextDepthIndex; depthHistoryValid = true; processedDepthBuffer = depth.buffer; inFlight = true
        let input = RetainedVideoFrame(buffer), output = RetainedVideoFrame(depth.buffer, textureReference: raw.1)
        let reference = RetainedVideoFrame(depth.source)
        let capture = !debugCaptured && ProcessInfo.processInfo.arguments.contains("--depth-capture")
        debugCaptured = debugCaptured || capture
        let capturedParameters = warpParams
        commands.addCompletedHandler { [weak self, input, output, reference] command in
            _ = input; _ = output; _ = reference
            let failure = command.status == .error ? (command.error?.localizedDescription ?? "3D 合成失败") : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failure = failure
                self.lastGPUMilliseconds = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
                #if DEBUG
                if capture, let context = self.ciContext {
                    let manifestURL = URL.documentsDirectory.appending(path: "depth-capture.json")
                    try? FileManager.default.removeItem(at: manifestURL)
                    do {
                        guard failure == nil else { throw RenderError.invalidFrame }
                        for (name, texture) in [("left", left), ("right", right)] {
                            guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: self.colorSpace]) else { throw RenderError.invalidFrame }
                            try context.writePNGRepresentation(of: image.oriented(.downMirrored),
                                to: URL.documentsDirectory.appending(path: "depth-\(name).png"), format: .RGBA8,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        }
                        let arguments = ProcessInfo.processInfo.arguments
                        let runID = arguments.firstIndex(of: "--smoke-run-id").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
                        let metadata: [String: Any] = ["runID": runID, "mapping": depth.subjectAccuracy ? "planar-coverage-v1" : "anchored-relief-v2", "projectionSampling": "proportion-protected-forward-v1", "proportionProtection": protectProportions,
                            "strength": capturedParameters.x, "popOut": capturedParameters.y, "disparityGain": disparityGain, "motionAlignment": alignMotion, "edgeRefinement": refineEdges, "subjectAccuracy": depth.subjectAccuracy, "depthContentRegion": [depth.contentRegion.x, depth.contentRegion.y, depth.contentRegion.z, depth.contentRegion.w],
                            "frontLimit": capturedParameters.z, "rearLimit": capturedParameters.w,
                            "width": width, "height": height, "displayMipLevels": left.mipmapLevelCount, "timestamp": ISO8601DateFormatter().string(from: Date())]
                        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
                    } catch {
                        // Diagnostic capture must not stop playback. No manifest
                        // means this run's eye images cannot be accepted as evidence.
                        try? FileManager.default.removeItem(at: manifestURL)
                    }
                }
                #endif
                self.inFlight = false
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
    var immersive = false
    @State private var renderer = StereoRenderer()
    @State private var aspect: Float = 16 / 9
    @State private var ready = false
    @State private var cinemaControls: Entity?

    var body: some View {
        Group {
            if immersive {
                RealityView { content, attachments in
                    do {
                        try await renderer.prepare()
                        guard !Task.isCancelled, model.request?.id == request.id else { return }
                        content.add(renderer.entity)
                        let sky = ModelEntity(mesh: .generateSphere(radius: 20), materials: [UnlitMaterial(color: UIColor(white: 0.025, alpha: 1))])
                        sky.scale = [-1, 1, 1]; sky.name = "CinemaBackground"
                        sky.isEnabled = model.library.darkCinema; content.add(sky)
                        positionCinema()
                        if let controls = attachments.entity(for: "controls") {
                            cinemaControls = controls
                            CinemaControlPlacement.place(controls, model: model, aspect: aspect)
                            content.add(controls)
                        }
                        if let captions = attachments.entity(for: "captions") { content.add(captions) }
                        ready = true
                    } catch {
                        if !Task.isCancelled, model.request?.id == request.id { model.rendererError = error.localizedDescription }
                    }
                } update: { content, attachments in
                    positionCinema()
                    if let controls = cinemaControls { CinemaControlPlacement.place(controls, model: model, aspect: aspect) }
                    content.entities.first(where: { $0.name == "CinemaBackground" })?.isEnabled = model.library.darkCinema
                    if let captions = attachments.entity(for: "captions") {
                        CinemaControlPlacement.placeCaptions(captions, model: model, aspect: aspect)
                    }
                    try? renderer.bindEyes(swapped: model.swapEyes)
                    renderer.setEyeCheck(model.eyeCheck)
                } attachments: {
                    Attachment(id: "controls") { CinemaControls(model: model) }
                    Attachment(id: "captions") {
                        CaptionOverlay(model: model).frame(width: 800).opacity(model.subtitleText.isEmpty ? 0 : 1)
                    }
                }
            } else {
        GeometryReader3D { geometry in
            RealityView { content in
                do {
                    try await renderer.prepare()
                    guard !Task.isCancelled, model.request?.id == request.id else { return }
                    content.add(renderer.entity)
                    let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                    renderer.fit(in: bounds.extents, centeredAt: bounds.center, aspect: aspect)
                    renderer.setEyeCheck(model.eyeCheck)
                    ready = true
                } catch is CancellationError {
                    // Removing the old view during engine fallback cancels material loading.
                } catch {
                    if model.request?.id == request.id, !Task.isCancelled {
                        model.rendererError = error.localizedDescription
                    }
                }
            } update: { content in
                guard model.request?.id == request.id else { return }
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                renderer.fit(in: bounds.extents, centeredAt: bounds.center, aspect: aspect)
                do { try renderer.bindEyes(swapped: model.swapEyes) }
                catch { model.rendererError = error.localizedDescription }
                renderer.setEyeCheck(model.eyeCheck)
            }
            .frame(width: CGFloat(geometry.size.width), height: CGFloat(geometry.size.height))
            .frame(depth: 0)
        }
        // Keep layout anchored at the window plane, with only the renderer's
        // explicit 5 mm gap. Default 3D depth would push the screen much farther
        // toward the viewer and magnify it over the transport controls.
        .frame(depth: 0)
            }
        }
        .gesture(SpatialTapGesture().targetedToEntity(renderer.entity).onEnded { _ in model.focus.reveal() })
        .task {
            guard immersive else { return }
            // Attachment height changes when screen adjustments expand. Keep
            // its top edge below the movie, including while playback is paused.
            while !Task.isCancelled {
                if let controls = cinemaControls { CinemaControlPlacement.place(controls, model: model, aspect: aspect) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .task(id: ready) {
            guard ready else { return }
            var lastBuffer: CVPixelBuffer?
            let stream = DepthStream(estimator: model.depthEstimator, requestID: request.id, onSceneReset: { [model] in
                guard model.request?.id == request.id else { return }
                model.depthSceneResets += 1
            }) { [model] ms in
                guard model.request?.id == request.id else { return }
                model.recordDepthPrediction(milliseconds: ms)
            }
            defer { stream.cancel() }
            var lastDepthVersion = -1
            var lastStrength: Float = -1
            var lastPopOut: Float = -1
            var lastProportionProtection: Bool?
            var lastMotionAlignment: Bool?
            var lastEdgeRefinement: Bool?
            var lastSubjectAccuracy: Bool?
            var lastDisparityLimits = SIMD2<Float>(repeating: -1)
            var lastRevision = model.depthRevision
            var presentation = DepthPresentationEnvelope()
            while !Task.isCancelled, model.request?.id == request.id {
                if let failure = renderer.failure { model.rendererError = failure; return }
                if !renderer.canRender {
                    try? await Task.sleep(for: .milliseconds(2))
                    continue
                }
                if lastRevision != model.depthRevision {
                    lastBuffer = nil; lastRevision = model.depthRevision; stream.reset(revision: lastRevision)
                }
                let newBuffer = model.copyVideoFrame()
                let disparityLimits = renderer.disparityLimits(distance: immersive ? model.library.screenDistance : nil)
                let strengthChanged = request.converts2D && (model.depthStrength != lastStrength || model.depthPopOut != lastPopOut
                    || (abs(disparityLimits.x - lastDisparityLimits.x) > 0.00001 || abs(disparityLimits.y - lastDisparityLimits.y) > 0.00001))
                let protectionChanged = request.converts2D && model.depthProportionProtection != lastProportionProtection
                let alignmentChanged = request.converts2D && (model.depthMotionAlignment != lastMotionAlignment || model.depthEdgeRefinement != lastEdgeRefinement)
                let accuracyChanged = request.converts2D && model.depthSubjectAccuracy != lastSubjectAccuracy
                let depthChangedWhilePaused = request.converts2D && !model.isPlaying && stream.version != lastDepthVersion
                if let failure = stream.error { model.rendererError = failure; return }
                if let buffer = newBuffer ?? ((strengthChanged || protectionChanged || alignmentChanged || accuracyChanged || depthChangedWhilePaused) ? lastBuffer : nil) {
                    do {
                        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                        var rendered = false
                        if request.converts2D && model.depthStrength > 0 {
                            if newBuffer != nil || strengthChanged || accuracyChanged || (depthChangedWhilePaused && stream.latest == nil) {
                                stream.offer(buffer, revision: model.depthRevision, subjectAccuracy: model.depthSubjectAccuracy)
                            }
                            let now = ProcessInfo.processInfo.systemUptime
                            let gain = presentation.update(now: now, capturedAt: stream.latest?.capturedAt,
                                                           generation: stream.generation, playing: model.isPlaying)
                            if let latest = stream.latest, now - latest.capturedAt <= 0.15 || !model.isPlaying {
                                rendered = try renderer.renderConverted(buffer, depth: latest.depth, strength: model.depthStrength, popOut: model.depthPopOut, protectProportions: model.depthProportionProtection, distance: immersive ? model.library.screenDistance : nil, swapped: model.swapEyes, disparityGain: gain, alignMotion: model.depthMotionAlignment, refineEdges: model.depthEdgeRefinement)
                                model.depthStatus = "Depth Anything V2 Small · 本机转换"
                                if rendered, newBuffer != nil {
                                    model.recordConvertedFrame(age: (ProcessInfo.processInfo.systemUptime - latest.capturedAt) * 1000)
                                }
                            } else {
                                let coverage = model.depthSubjectAccuracy ? StereoReprojector.coverageScale(parameters:
                                    SIMD4(model.depthStrength, model.depthPopOut, disparityLimits.x, disparityLimits.y)) : 1
                                rendered = try renderer.render(buffer, swapped: model.swapEyes, layout: .flat, coverageScale: coverage)
                                model.depthStatus = "正在更新深度 · 暂用平面画面"
                            }
                            if rendered, newBuffer != nil {
                                model.depthGainSamples.append(gain)
                                if model.depthGainSamples.count > 600 { model.depthGainSamples.removeFirst() }
                                model.recordDepthDisplay(gpuMilliseconds: renderer.lastGPUMilliseconds)
                            }
                            lastDepthVersion = stream.version
                        } else {
                            rendered = try renderer.render(buffer, swapped: model.swapEyes, layout: request.layout)
                            if request.converts2D { model.depthStatus = "强度为 0 · 平面效果" }
                        }
                        if rendered {
                            lastDepthVersion = stream.version
                            lastBuffer = buffer; lastStrength = model.depthStrength; lastPopOut = model.depthPopOut
                            lastProportionProtection = model.depthProportionProtection
                            lastMotionAlignment = model.depthMotionAlignment
                            lastEdgeRefinement = model.depthEdgeRefinement
                            lastSubjectAccuracy = model.depthSubjectAccuracy
                            lastDisparityLimits = disparityLimits
                            aspect = request.layout.displayAspect(width: width, height: height)
                            let eye = request.layout.eyeRegions(width: width, height: height).left
                            model.frameSize = !request.layout.isStereo
                                ? "2D \(width) × \(height) → AI 左右眼"
                                : "\(width) × \(height) → 左右眼各 \(Int(eye.width)) × \(Int(eye.height))"
                            model.depthScreenWidthMeters = renderer.entity.scale.x
                            model.renderedFrames += 1
                            model.stereoDisplayAspect = Double(renderer.entity.scale.x / renderer.entity.scale.y)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        if model.request?.id == request.id { model.rendererError = error.localizedDescription }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(request.converts2D ? 2 : 16))
            }
        }
    }
    private func positionCinema() {
        renderer.entity.position = [0, model.library.screenHeight, -model.library.screenDistance]
        renderer.entity.scale = [model.library.screenWidth, model.library.screenWidth / max(0.1, aspect), 1]
    }

}
