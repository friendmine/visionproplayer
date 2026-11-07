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
    @State private var page: PlaybackSettingsPage?
    @Bindable var model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            if let request = model.request, request.isCinema {
                if request.isSpatialVideo, let player = model.nativePlayer {
                    SpatialVideoView(model: model, player: player, immersive: true, cinemaPage: $page).id(request.id)
                } else { StereoPlayerView(model: model, request: request, immersive: true, cinemaPage: $page).id(request.id) }
            } else if model.cinemaActive {
                RealityView { content, attachments in
                    if let controls = attachments.entity(for: "recovery") {
                        controls.position = [0, 1.35, -2]
                        content.add(controls)
                    }
                } attachments: {
                    Attachment(id: "recovery") { CinemaControls(model: model, panel: $page) }
                }
            }
        }.onChange(of: page) { _, destination in
            model.focus.hold("cinema-panel", destination != nil)
        }.onChange(of: phase) { _, value in
            if value == .background { model.pauseForBackground(); model.checkpoint() }
        }.onDisappear {
            page = nil
            model.focus.hold("cinema-panel", false)
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
    @Binding var panel: PlaybackSettingsPage?

    var body: some View {
        VStack(spacing: 16) {
            // Keep the exit outside every settings page and the seek-preview row.
            // Immersive navigation must not depend on opening a popover.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.movieTitle).lineLimit(1).font(.headline)
                    Text(model.playbackNotice ?? model.pictureTitle).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if panel != nil {
                    Button("返回播放", systemImage: "chevron.left") { panel = nil }
                }
                Button(model.cinemaTransition ? "正在退出…" : "退出影院", systemImage: "arrow.down.right.and.arrow.up.left") {
                    leaveCinema()
                }.disabled(model.cinemaTransition).frame(minHeight: 44)
                    .accessibilityHint("返回播放窗口并保留当前进度")
            }
            Group {
                if panel == nil { transport }
                else { PlaybackSettingsPanel(model: model, page: $panel).frame(height: 390) }
            }.disabled(model.cinemaTransition)
        }.padding(24).frame(width: 700).glassBackgroundEffect()
            .opacity(model.focus.visible ? 1 : 0).allowsHitTesting(model.focus.visible).accessibilityHidden(!model.focus.visible)
            .animation(.easeInOut(duration: 0.25), value: model.focus.visible)
            .simultaneousGesture(TapGesture().onEnded { model.focus.reveal() })
            .modifier(FocusPlaybackModifier(model: model))
    }
    private var transport: some View {
        VStack(spacing: 12) {
            PlaybackSeekBar(model: model, holdKey: "cinema-seek")
            SeekPreviewControlsRow(model: model, surface: "cinema-controls") {
                AdaptivePlaybackControls(model: model, page: $panel)
            }
            if let error = model.errorMessage ?? model.rendererError {
                HStack {
                    Text(error).font(.callout)
                    Button("重试") { model.retryPlayback() }
                }
            } else if let title = model.loadingTitle { ProgressView(title) }
        }
    }
    private func leaveCinema() {
        guard !model.cinemaTransition else { return }
        model.cinemaTransition = true
        model.focus.hold("cinema-exit", true)
        Task { @MainActor in
            defer {
                model.cinemaTransition = false
                model.focus.hold("cinema-exit", false)
            }
            // Restore a window before dismissing the app's immersive scene.
            openWindow(id: "main")
            model.setCinema(false)
            await dismissImmersiveSpace()
        }
    }
}
