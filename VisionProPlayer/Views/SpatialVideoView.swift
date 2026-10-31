import AVFoundation
import RealityKit
import SwiftUI

/// Let Apple's multiview decoder and video component keep both MV-HEVC views.
/// The existing BGRA/AI path only receives a single view and must not be used.
struct SpatialVideoView: View {
    let model: PlayerModel
    let player: AVPlayer
    var immersive = false
    @State private var video = Entity()
    @State private var recordedStereo = false
    @State private var size = SIMD2<Float>(1, 9.0 / 16.0)
    @State private var cinemaControls: Entity?

    var body: some View {
        Group {
            if immersive {
                RealityView { content, attachments in
                    configure(); content.add(video)
                    let sky = ModelEntity(mesh: .generateSphere(radius: 20), materials: [UnlitMaterial(color: UIColor(white: 0.025, alpha: 1))])
                    sky.scale = [-1, 1, 1]; sky.name = "CinemaBackground"
                    sky.isEnabled = model.library.darkCinema; content.add(sky)
                    positionCinema()
                    if let controls = attachments.entity(for: "controls") {
                        cinemaControls = controls
                        CinemaControlPlacement.place(controls, model: model, aspect: size.x / size.y)
                        content.add(controls)
                    }
                    if let captions = attachments.entity(for: "captions") { content.add(captions) }
                } update: { content, attachments in
                    positionCinema()
                    if let controls = cinemaControls { CinemaControlPlacement.place(controls, model: model, aspect: size.x / size.y) }
                    content.entities.first(where: { $0.name == "CinemaBackground" })?.isEnabled = model.library.darkCinema
                    if let captions = attachments.entity(for: "captions") {
                        captions.position = [0, model.library.screenHeight - model.library.screenWidth * size.y / size.x * 0.36, -model.library.screenDistance + 0.03]
                        captions.scale = [1.5, 1.5, 1.5]
                    }
                } attachments: {
                    Attachment(id: "controls") { CinemaControls(model: model) }
                    Attachment(id: "captions") { CaptionOverlay(text: model.subtitleText).frame(width: 800).opacity(model.subtitleText.isEmpty ? 0 : 1) }
                }
            } else {
                GeometryReader3D { geometry in
                    RealityView { content in
                        configure(); content.add(video)
                        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                        fit(bounds)
                    } update: { content in
                        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
                        fit(bounds)
                    }
                }.frame(depth: 0)
            }
        }
        .task {
            while !Task.isCancelled {
                if let controls = cinemaControls { CinemaControlPlacement.place(controls, model: model, aspect: size.x / size.y) }
                if let component = video.components[VideoPlayerComponent.self] {
                    let current = component.playerScreenSize
                    if current.x > 0, current.y > 0, current.x.isFinite, current.y.isFinite, current != size { size = current }
                    model.stereoDisplayAspect = Double(size.x / size.y)
                    let stereo = component.viewingMode == .stereo
                    if model.spatialStereoActive != stereo { model.spatialStereoActive = stereo }
                    #if DEBUG
                    if stereo, !recordedStereo, model.isPlaying, model.elapsed > 0.5 {
                        let report = model.smokeMetadata().merging([
                            "sample": immersive ? "spatial-cinema" : "spatial-window",
                            "detectedMultiview": model.request?.isSpatialVideo == true,
                            "actualViewingMode": "stereo",
                            "usesSingleViewTextureOutput": model.request?.usesTextureOutput ?? true,
                            "passed": model.request?.isSpatialVideo == true && model.request?.usesTextureOutput == false,
                            "scope": "Real VideoPlayerComponent stereo mode during playback; contains no source filename, asset ID or video content."
                        ]) { _, new in new }
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: URL.documentsDirectory.appending(path: immersive ? "spatial-cinema.json" : "spatial-window.json"), options: .atomic)
                            recordedStereo = true
                        }
                    }
                    #endif
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onDisappear { video.components.remove(VideoPlayerComponent.self) }
    }
    private func configure() {
        var component = VideoPlayerComponent(avPlayer: player)
        component.desiredViewingMode = .stereo
        // A fixed stereo screen matches our controls and sizing. No custom
        // BGRA extraction, AI conversion, or eye splitting occurs here.
        if #available(visionOS 26.0, *) { component.desiredSpatialVideoMode = .screen }
        video.components.set(component)
    }
    private func fit(_ bounds: BoundingBox) {
        let scale = max(0.001, min(abs(bounds.extents.x) / size.x, abs(bounds.extents.y) / size.y))
        video.scale = SIMD3(repeating: scale)
        video.position = bounds.center + SIMD3(0, 0, 0.005)
    }
    private func positionCinema() {
        video.position = [0, model.library.screenHeight, -model.library.screenDistance]
        video.scale = SIMD3(repeating: model.library.screenWidth / size.x)
    }
}
