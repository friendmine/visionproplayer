import SwiftUI
import RealityKit

enum CinemaControlPlacement {
    static func position(screenHeight: Float, screenWidth: Float, aspect: Float,
                         distance: Float, controlsTop: Float) -> SIMD3<Float> {
        let bottom = screenHeight - screenWidth / max(0.1, aspect) / 2
        return [0, bottom - 0.14 - controlsTop, -distance + 0.12]
    }

    @MainActor static func placeCaptions(_ captions: Entity, model: PlayerModel, aspect: Float) {
        let offset = model.library.screenWidth / max(0.1, aspect) * 0.36
        captions.position = [0, model.library.screenHeight + (model.captionAtTop ? offset : -offset),
                             -model.library.screenDistance + 0.03]
        captions.scale = SIMD3(repeating: 1.5)
    }

    @MainActor static func place(_ controls: Entity, model: PlayerModel, aspect: Float) {
        controls.scale = SIMD3(repeating: 1.2)
        let bounds = controls.visualBounds(relativeTo: controls)
        let top = bounds.extents.y > 0 && bounds.max.y.isFinite ? bounds.max.y * 1.2 : 0.15
        controls.position = position(screenHeight: model.library.screenHeight,
                                     screenWidth: model.library.screenWidth, aspect: aspect,
                                     distance: model.library.screenDistance, controlsTop: top)
    }
}

struct CinemaSettings: View {
    @Bindable var model: PlayerModel
    let enter: () async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("空间影院").font(.title2)
            Toggle("暗色环境", isOn: Binding(get: { model.library.darkCinema }, set: { model.library.darkCinema = $0 }))
            Text("关闭时保留现实环境。进入后主窗口收起，影院下方仍可控制播放和退出。").font(.callout).foregroundStyle(.secondary)
            ScreenAdjustments(model: model)
            Button("进入影院", systemImage: "vision.pro") { Task { await enter() } }
                .buttonStyle(.borderedProminent).disabled(model.cinemaTransition || model.request == nil)
        }
    }
}

struct ScreenAdjustments: View {
    @Bindable var model: PlayerModel
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text("屏幕宽度"); Spacer(); Text("\(model.library.screenWidth, specifier: "%.1f") 米") }
            Slider(value: Binding(get: { model.library.screenWidth }, set: { model.library.screenWidth = $0 }), in: 1.5...5).accessibilityLabel("屏幕宽度")
            HStack { Text("观看距离"); Spacer(); Text("\(model.library.screenDistance, specifier: "%.1f") 米") }
            Slider(value: Binding(get: { model.library.screenDistance }, set: { model.library.screenDistance = $0 }), in: 2...6).accessibilityLabel("观看距离")
            HStack { Text("屏幕高度"); Spacer(); Text("\(model.library.screenHeight, specifier: "%.1f") 米") }
            Slider(value: Binding(get: { model.library.screenHeight }, set: { model.library.screenHeight = $0 }), in: 1...2.2).accessibilityLabel("屏幕高度")
            Button("恢复默认屏幕") { model.library.screenWidth = 3; model.library.screenDistance = 3; model.library.screenHeight = 1.5 }
        }.font(.callout)
    }
}

struct CinemaScene: View {
    @Bindable var model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            if let request = model.request, request.isCinema {
                if request.isSpatialVideo, let player = model.nativePlayer {
                    SpatialVideoView(model: model, player: player, immersive: true).id(request.id)
                } else { StereoPlayerView(model: model, request: request, immersive: true).id(request.id) }
            }
        }.onChange(of: phase) { _, value in
            if value == .background { model.pauseForBackground(); model.checkpoint() }
        }.onDisappear {
            if model.cinemaActive {
                model.pauseForBackground(); model.setCinema(false); openWindow(id: "main")
            }
        }
    }
}

struct CinemaControls: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var adjust = false
    @State private var tracks = false
    @State private var depthEffects = false
    var body: some View {
        Group {
            if tracks {
                TrackSettings(model: model, done: { tracks = false }).frame(height: 390)
            } else {
                transport
            }
        }.padding(24).frame(width: 700).glassBackgroundEffect()
            .opacity(model.focus.visible ? 1 : 0).allowsHitTesting(model.focus.visible).accessibilityHidden(!model.focus.visible)
            .animation(.easeInOut(duration: 0.25), value: model.focus.visible)
            .simultaneousGesture(TapGesture().onEnded { model.focus.reveal() })
            .onChange(of: adjust) { _, value in model.focus.hold("cinema-adjust", value) }
            .onChange(of: tracks) { _, value in model.focus.hold("cinema-tracks", value) }
            .onChange(of: depthEffects) { _, value in model.focus.hold("cinema-depth", value) }
            .onDisappear {
                for key in ["cinema-adjust", "cinema-depth", "cinema-tracks"] { model.focus.hold(key, false) }
            }
            .modifier(FocusPlaybackModifier(model: model))
    }
    private var transport: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.movieTitle).lineLimit(1).font(.headline)
                Spacer()
                Button("字幕与音轨", systemImage: "captions.bubble") {
                    model.loadTracks()
                    tracks = true
                }
                Button("返回窗口", systemImage: "arrow.down.right.and.arrow.up.left") {
                    Task {
                        openWindow(id: "main")
                        model.setCinema(false)
                        await dismissImmersiveSpace()
                    }
                }
            }
            PlaybackSeekBar(model: model, holdKey: "cinema-seek")
            SeekPreviewControlsRow(model: model, surface: "cinema-controls") {
                HStack(spacing: 24) {
                    Button("后退 10 秒", systemImage: "gobackward.10") { model.skip(-10) }.labelStyle(.iconOnly)
                    Button(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }.labelStyle(.iconOnly)
                    Button("快进 10 秒", systemImage: "goforward.10") { model.skip(10) }.labelStyle(.iconOnly)
                    Spacer()
                    if model.request?.converts2D == true {
                        Button("立体效果", systemImage: "view.3d") { depthEffects = true }
                            .popover(isPresented: $depthEffects) {
                                ScrollView { DepthEffectControls(model: model).padding(24) }
                                    .frame(width: 430).frame(maxHeight: 560)
                            }
                    }
                    Button(adjust ? "收起屏幕调整" : "调整屏幕", systemImage: "slider.horizontal.3") { adjust.toggle() }
                }
            }
            if adjust { ScreenAdjustments(model: model) }
            if let error = model.errorMessage ?? model.rendererError { Text(error).foregroundStyle(.orange).font(.caption) }
        }
    }
}
