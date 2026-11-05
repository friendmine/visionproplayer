import SwiftUI
import UniformTypeIdentifiers

struct PlayerScreen: View {
    @Bindable var model: PlayerModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var picture = false
    @State private var tracks = false
    @State private var cinema = false
    @State private var more = false

    private var stereoControls: Bool {
        guard let request = model.request else { return false }
        return request.layout.isStereo || request.converts2D || request.isSpatialVideo
    }
    private var controlsVisible: Bool { model.focus.visible }
    private var videoAspect: CGFloat {
        let ratio = model.stereoDisplayAspect
        return ratio.isFinite && ratio > 0 ? CGFloat(ratio) : 16 / 9
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button("片库", systemImage: "chevron.left") { Task { await leave() } }.frame(minHeight: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.movieTitle).font(.headline).lineLimit(1)
                    Text(model.pictureTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let film = model.currentFilm {
                    Button(film.favorite ? "取消收藏" : "收藏", systemImage: film.favorite ? "heart.fill" : "heart") { model.library.update(film.id) { $0.favorite.toggle() }; reveal() }.labelStyle(.iconOnly)
                }
                Button("画面", systemImage: "view.3d") { picture = true; reveal() }
                    .popover(isPresented: $picture) { PictureSettings(model: model).padding(24).frame(width: 430) }
                Button("影院", systemImage: "vision.pro") { cinema = true; reveal() }
                    .popover(isPresented: $cinema) { CinemaSettings(model: model, enter: enterCinema).padding(24).frame(width: 430) }
            }.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
            if stereoControls {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * videoAspect)
                    videoStage
                        .frame(width: max(1, width), height: max(1, width / videoAspect))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                // Reserve a separate row: RealityKit's forward screen plane
                // cannot cover the slider, and controls never resize the movie.
                transport.frame(maxWidth: 960).opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
            } else {
                videoStage
            }
        }.padding(24)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: model.isPlaying) { _, _ in reveal() }
            .onChange(of: picture) { _, value in if !value { model.savePicturePreferences(); reveal() } }
            .onChange(of: tracks) { _, value in if !value { reveal() } }
            .onChange(of: cinema) { _, value in if !value { reveal() } }
            .onChange(of: picture) { _, value in model.focus.hold("window-picture", value) }
            .onChange(of: tracks) { _, value in model.focus.hold("window-tracks", value) }
            .onChange(of: cinema) { _, value in model.focus.hold("window-cinema", value) }
            .onChange(of: more) { _, value in model.focus.hold("window-more", value) }
            .onDisappear {
                for key in ["window-picture", "window-tracks", "window-cinema", "window-more"] { model.focus.hold(key, false) }
            }
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            .modifier(FocusPlaybackModifier(model: model))
    }
    private var videoStage: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.95)
            Group {
                if model.cinemaActive {
                    ContentUnavailableView("正在空间影院播放", systemImage: "vision.pro", description: Text("可以在影院下方调整屏幕或退出影院。"))
                } else if let request = model.request {
                    if request.isSpatialVideo, let player = model.nativePlayer { SpatialVideoView(model: model, player: player).id(request.id) }
                    else if request.usesTextureOutput { StereoPlayerView(model: model, request: request).id(request.id) }
                    else if request.engine == .vlc { VLCPlayerView(model: model).id(request.id) }
                    else if let player = model.nativePlayer { NativeVideoSurface(player: player) }
                } else { ProgressView("正在打开影片…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.contentShape(Rectangle()).onTapGesture { reveal() }.offset(z: stereoControls ? 24 : 0)
            if !model.subtitleText.isEmpty && !model.cinemaActive {
                CaptionOverlay(model: model)
                    .padding(model.captionAtTop ? .top : .bottom, model.captionAtTop || stereoControls ? 24 : (controlsVisible ? 150 : 30))
                    .padding(.horizontal, 32)
                    .frame(maxHeight: .infinity, alignment: model.captionAtTop ? .top : .bottom)
                    .offset(z: stereoControls ? 24 : 0.02)
                    .allowsHitTesting(false)
            }
            if model.errorMessage != nil || model.rendererError != nil {
                VStack(spacing: 16) {
                    Label("暂时无法播放这部影片", systemImage: "exclamationmark.triangle").font(.title3)
                    Text(model.errorMessage ?? model.rendererError ?? "").font(.callout).lineLimit(4)
                    HStack {
                        Button("重试") { model.retryPlayback() }
                        if model.isPlaying { Button("关闭提示") { model.errorMessage = nil; model.rendererError = nil } }
                        Button("返回片库") { Task { await leave() } }
                    }
                }.padding(28).frame(maxWidth: 550).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            } else if model.hasEnded {
                HStack(spacing: 20) {
                    Button("重新播放", systemImage: "arrow.counterclockwise") { model.restart(); reveal() }
                    Button("返回片库", systemImage: "square.grid.2x2") { Task { await leave() } }
                }.padding(24).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            } else if model.stateText.contains("打开") || model.stateText.contains("缓冲") || model.isSwitchingEngine {
                ProgressView(model.isSwitchingEngine ? "正在尝试兼容播放…" : model.stateText)
                    .padding(24).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            }
            if !stereoControls {
                transport.padding(20).opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible).offset(z: 0.04)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 26))
    }
    private var transport: some View {
        VStack(spacing: 10) {
            PlaybackSeekBar(model: model, holdKey: "window-seek").font(.caption)
            SeekPreviewControlsRow(model: model, surface: "window-controls") {
                HStack(spacing: 20) {
                    Button("后退 10 秒", systemImage: "gobackward.10") { model.skip(-10); reveal() }.labelStyle(.iconOnly).disabled(!model.isSeekable)
                    Button(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback(); reveal() }
                        .labelStyle(.iconOnly).keyboardShortcut(.space, modifiers: []).frame(minWidth: 60, minHeight: 60)
                    Button("快进 10 秒", systemImage: "goforward.10") { model.skip(10); reveal() }.labelStyle(.iconOnly).disabled(!model.isSeekable)
                    Spacer()
                    Button("字幕与音轨", systemImage: "captions.bubble") { model.loadTracks(); tracks = true; reveal() }
                        .popover(isPresented: $tracks) { TrackSettings(model: model).frame(width: 460, height: 560) }
                    Button("更多", systemImage: "ellipsis") { more = true; reveal() }.labelStyle(.iconOnly)
                        .popover(isPresented: $more) {
                        VStack(alignment: .leading, spacing: 20) {
                        Button("从头播放", systemImage: "arrow.counterclockwise") { model.restart(); reveal() }
                        if model.currentFilm?.title.hasPrefix("Big Buck Bunny") == true || model.request?.url.lastPathComponent.hasPrefix("BBB-") == true {
                            Text("Big Buck Bunny © 2008 Blender Foundation · CC BY 3.0")
                        }
                        Button("返回片库", systemImage: "square.grid.2x2") { Task { await leave() } }
                        }.padding(24).frame(width: 300)
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }
    private func reveal() { model.focus.reveal() }
    private func leave() async {
        if model.cinemaActive { await dismissImmersiveSpace(); model.setCinema(false) }
        model.returnToLibrary()
    }
    private func enterCinema() async {
        guard !model.cinemaTransition, model.request != nil else { return }
        cinema = false; model.cinemaTransition = true
        defer { model.cinemaTransition = false }
        switch await openImmersiveSpace(id: "Cinema") {
        case .opened:
            model.setCinema(true); await model.waitForPendingChange(); dismissWindow(id: "main")
        case .userCancelled: break
        case .error: model.errorMessage = "暂时无法打开空间影院，请关闭其他沉浸式 App 后重试。"
        @unknown default: break
        }
    }
}

struct CaptionOverlay: View {
    let model: PlayerModel
    private var font: Font {
        switch model.selectedSubtitle == "external" ? model.library.externalCaptionSize : .standard {
        case .small: .body
        case .standard: .title3
        case .large: .title
        }
    }
    var body: some View {
        Text(model.subtitleText).font(font.weight(.medium)).multilineTextAlignment(.center)
            .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 9)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("字幕：\(model.subtitleText)")
    }
}

struct PictureSettings: View {
    @Bindable var model: PlayerModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("画面设置").font(.title2)
                if model.request?.isSpatialVideo == true {
                    Label(model.spatialStereoActive ? "正在播放原生双眼画面" : "正在准备原生空间画面", systemImage: "vision.pro")
                    Text("保留影片的左右眼画面，无需 AI 转换或手动分屏。").font(.callout).foregroundStyle(.secondary)
                } else if model.request?.layout.isStereo == false {
                    Picker("观看效果", selection: Binding(get: { model.request?.converts2D ?? false }, set: { model.setDepthConversion($0) })) {
                        Text("普通 2D").tag(false); Text("AI 立体").tag(true)
                    }.pickerStyle(.segmented).disabled(model.isClosing)
                    if model.request?.converts2D == true {
                        DepthEffectControls(model: model)
                    }
                } else {
                    Label("使用影片自带的左右眼画面", systemImage: "view.3d")
                    Toggle("交换左右眼", isOn: $model.swapEyes).onChange(of: model.swapEyes) { _, _ in model.savePicturePreferences() }
                }
                if model.request?.isSpatialVideo != true {
                DisclosureGroup("影片格式 · \(model.request?.layout.title ?? "普通 2D")") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("左右并排、上下排列或比例异常时调整。上下格式默认上方为左眼，可交换左右眼。").font(.caption).foregroundStyle(.secondary)
                        Picker("影片格式", selection: Binding(get: { model.request?.layout ?? .flat }, set: { model.setLayout($0) })) {
                            ForEach(StereoLayout.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline).labelsHidden().disabled(model.isClosing)
                    }.padding(.top, 14)
                }
                }
                if model.currentFilm != nil { Label("自动记住这部影片的设置", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxHeight: 620)
    }
}

struct DepthEffectControls: View {
    @Bindable var model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("观影预设", selection: Binding(get: { model.currentDepthEffect.preset }, set: { model.selectDepthPreset($0) })) {
                ForEach(DepthPreset.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack { Text("立体强度"); Spacer(); Text("\(Int(model.depthStrength * 100))%").monospacedDigit() }
            Slider(value: Binding(get: { model.depthStrength }, set: { model.depthStrength = $0; model.depthPreset = .custom }), in: 0...1, onEditingChanged: { editing in
                if !editing { model.savePicturePreferences() }
            }).accessibilityLabel("立体强度")
            Text("控制前后层次；设为 0 可对比平面画面。").font(.caption).foregroundStyle(.secondary)
            HStack { Text("出屏程度"); Spacer(); Text("\(Int(model.depthPopOut * 100))%").monospacedDigit() }
            Slider(value: Binding(get: { model.depthPopOut }, set: { model.depthPopOut = $0; model.depthPreset = .custom }), in: 0...1, onEditingChanged: { editing in
                if !editing { model.savePicturePreferences() }
            }).accessibilityLabel("出屏程度")
            Text("向右让前景更靠近你，并保留远景在屏幕后。立体强度调节前后层次；强度为 0 时保持平面。").font(.caption).foregroundStyle(.secondary)
            Toggle("比例保护", isOn: Binding(get: { model.depthProportionProtection }, set: {
                model.depthProportionProtection = $0; model.depthPreset = .custom; model.savePicturePreferences()
            }))
            #if DEBUG
            DisclosureGroup("实验对比") { MotionAlignmentComparison(model: model) }
            #endif
            Text("减少脸部、四肢等区域的拉伸和扭斜，尽量保留原片形状。开启后部分局部景深会收敛。").font(.caption).foregroundStyle(.secondary)
            Button(model.currentDepthEffect == model.library.defaultDepthEffect ? "已是新影片默认效果" : "设为新影片默认效果") {
                model.library.saveDefaultDepthEffect(model.currentDepthEffect)
            }
            .disabled(model.currentDepthEffect == model.library.defaultDepthEffect)
            Text("新加入影片开启 AI 立体时使用，已有影片沿用各自设置。").font(.caption).foregroundStyle(.secondary)
            Button("使用新影片默认效果") { model.applyDepthEffect(model.library.defaultDepthEffect) }
                .disabled(model.currentDepthEffect == model.library.defaultDepthEffect)
            Text("实验性效果。遮挡处仍可能拉伸；若出现重影，可降低强度或出屏程度。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
struct MotionAlignmentComparison: View {
    @Bindable var model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("画面处理", selection: $model.depthSubjectAccuracy) {
                Text("稳定版 0.6.4").tag(false)
                Text("人物与前景 · 实验").tag(true)
            }
            Text("新版保留深度平面，轻微等比放大并裁去边缘，避免边缘回拉。保留运动对齐和比例保护。保持参数不变作对比；切换后重新估计当前画面深度，只在本次使用期间生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif

struct TrackSettings: View {
    @Bindable var model: PlayerModel
    var done: (() -> Void)? = nil
    @State private var importing = false
    var body: some View {
        @Bindable var library = model.library
        NavigationStack {
            Form {
                Section("音轨") {
                    if model.audioTracks.isEmpty { Text("此影片未提供可选音轨").foregroundStyle(.secondary) }
                    else {
                        Picker("音轨", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                            if model.selectedAudio.isEmpty { Text("默认").tag("") }
                            ForEach(model.audioTracks) { Text($0.title).tag($0.id) }
                        }
                    }
                }
                Section("字幕") {
                    Picker("字幕", selection: Binding(get: { model.selectedSubtitle }, set: { model.selectSubtitle($0) })) {
                        Text("关闭").tag("off")
                        if !model.subtitleCues.isEmpty { Text("已导入的字幕").tag("external") }
                        if !(model.request?.engine == .vlc && model.request?.usesTextureOutput == true) {
                            ForEach(model.subtitleTracks) { Text($0.title).tag($0.id) }
                        }
                    }
                    Button("导入 SRT / WebVTT", systemImage: "doc.badge.plus") { importing = true }.disabled(model.currentFilm == nil)
                    if model.request?.engine == .vlc && model.request?.usesTextureOutput == true {
                        Text("这条 3D 播放路径请使用外挂文字字幕，避免内嵌字幕被左右画面切分。").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.selectedSubtitle == "external" {
                        Picker("字号", selection: $library.externalCaptionSize) {
                            Text("小").tag(CaptionSize.small)
                            Text("标准").tag(CaptionSize.standard)
                            Text("大").tag(CaptionSize.large)
                        }.pickerStyle(.segmented)
                        Picker("位置", selection: $library.externalCaptionAtTop) {
                            Text("下方").tag(false)
                            Text("上方").tag(true)
                        }.pickerStyle(.segmented)
                        Stepper("字幕延后 \(model.subtitleOffset, specifier: "%.1f") 秒", value: $model.subtitleOffset, in: -10...10, step: 0.5)
                            .onChange(of: model.subtitleOffset) { _, _ in model.savePicturePreferences() }
                    }
                }
            }.navigationTitle("字幕与音轨")
                .toolbar {
                    if let done { ToolbarItem(placement: .confirmationAction) { Button("完成", action: done) } }
                }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]) { result in
            if case .success(let url) = result { model.importSubtitle(url) }
        }
    }
}
