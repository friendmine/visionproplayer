import SwiftUI
import RealityKit

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
    @State private var seek = 0.0
    @State private var dragging = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.movieTitle).lineLimit(1).font(.headline)
                Spacer()
                Button("返回窗口", systemImage: "arrow.down.right.and.arrow.up.left") {
                    Task {
                        openWindow(id: "main")
                        model.setCinema(false)
                        await dismissImmersiveSpace()
                    }
                }
            }
            HStack {
                Text(PlayerModel.clock(model.elapsed)).monospacedDigit()
                Slider(value: $seek, in: 0...1, onEditingChanged: { editing in dragging = editing; if !editing { model.seek(to: seek) } }).accessibilityLabel("播放进度").disabled(!model.isSeekable)
                Text(PlayerModel.clock(model.duration)).monospacedDigit()
            }
            HStack(spacing: 24) {
                Button("后退 10 秒", systemImage: "gobackward.10") { model.skip(-10) }.labelStyle(.iconOnly)
                Button(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }.labelStyle(.iconOnly)
                Button("快进 10 秒", systemImage: "goforward.10") { model.skip(10) }.labelStyle(.iconOnly)
                Spacer()
                Button(adjust ? "收起屏幕调整" : "调整屏幕", systemImage: "slider.horizontal.3") { adjust.toggle() }
            }
            if adjust { ScreenAdjustments(model: model) }
            if let error = model.errorMessage ?? model.rendererError { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(24).frame(width: 700).glassBackgroundEffect()
            .onChange(of: model.progress) { _, value in if !dragging { seek = value } }
    }
}
