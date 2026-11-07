import SwiftUI
import UniformTypeIdentifiers

struct PlayerScreen: View {
    @Bindable var model: PlayerModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    let browsePhotos: () -> Void
    let manageServer: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var page: PlaybackSettingsPage?

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
                    Text(model.playbackNotice ?? model.pictureTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()

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
            .popover(isPresented: Binding(get: { page != nil }, set: { if !$0 { page = nil } }),
                     attachmentAnchor: .point(.bottomTrailing)) {
                VStack(spacing: 14) {
                    HStack {
                        Text("观看设置").font(.title2.bold())
                        Spacer()
                        Button("返回播放") { page = nil }
                    }
                    PlaybackSettingsPanel(model: model, page: $page, enterCinema: enterCinema, leaveLibrary: leave)
                }.padding(24).frame(width: 490, height: 470)
            }
            .onChange(of: page) { _, destination in
                model.focus.hold("window-settings", destination != nil)
            }
            .onDisappear { model.focus.hold("window-settings", false) }
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
                } else { Color.clear }
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
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryButtons }
                        VStack { recoveryButtons }
                    }
                }.padding(28).frame(maxWidth: 550).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            } else if model.isOpeningPhoto {
                VStack(spacing: 16) {
                    if let value = model.photoLoadingProgress {
                        ProgressView(value: value).frame(maxWidth: 260)
                        Text(value, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    } else { ProgressView() }
                    Text(model.loadingTitle ?? "正在打开相册视频…")
                    Button("取消") { Task { await leave() } }
                }.padding(24).glassBackgroundEffect().frame(maxHeight: .infinity)
            } else if model.hasEnded {
                HStack(spacing: 20) {
                    Button("重新播放", systemImage: "arrow.counterclockwise") { model.restart(); reveal() }
                    Button("返回片库", systemImage: "square.grid.2x2") { Task { await leave() } }
                }.padding(24).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            } else if let title = model.loadingTitle ?? (model.request == nil ? "正在打开影片…" : nil) {
                VStack(spacing: 16) {
                    ProgressView(title)
                    Button("取消播放") { Task { await leave() } }
                }.padding(24).glassBackgroundEffect().frame(maxHeight: .infinity).offset(z: stereoControls ? 32 : 0.04)
            }
            if !stereoControls {
                transport.padding(20).opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible).offset(z: 0.04)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 26))
    }
    @ViewBuilder private var recoveryButtons: some View {
        Button("重试") { model.retryPlayback() }
        if model.sourceRecovery == .photoPermission, let url = URL(string: UIApplication.openSettingsURLString) {
            Button("相册访问设置") { openURL(url) }
        } else if model.sourceRecovery == .choosePhoto {
            Button("重新选择视频") { Task { await leave(); browsePhotos() } }
        } else if model.sourceRecovery == .server || model.currentFilm?.networkServerID != nil {
            Button("管理服务器") { Task { await leave(); manageServer() } }
        }
        if model.isPlaying { Button("关闭提示") { model.errorMessage = nil; model.rendererError = nil } }
        Button("返回片库") { Task { await leave() } }
    }
    private var transport: some View {
        VStack(spacing: 10) {
            PlaybackSeekBar(model: model, holdKey: "window-seek").font(.caption)
            SeekPreviewControlsRow(model: model, surface: "window-controls") {
                AdaptivePlaybackControls(model: model, page: $page)

            }
        }.padding(.horizontal, 24).padding(.vertical, 14).glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }
    private func reveal() { model.focus.reveal() }
    private func leave() async {
        model.errorMessage = nil
        model.rendererError = nil
        model.missingFilmID = nil
        if model.cinemaActive { await dismissImmersiveSpace(); model.setCinema(false) }
        model.returnToLibrary()
    }
    private func enterCinema() async {
        guard !model.cinemaTransition, model.request != nil else { return }
        page = nil; model.cinemaTransition = true
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
    var done: (() -> Void)? = nil
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    LabeledContent("当前效果", value: model.pictureTitle).font(.headline)
                    Spacer()
                    if let done { Button("完成", action: done) }
                }
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
    @State private var adjustments = false
    @State private var savedDefault = false
    private var effectDescription: String {
        switch model.currentDepthEffect.preset {
        case .natural: "柔和的前后层次，适合日常观看。"
        case .foreground: "让前景更靠近你，保留远景层次。"
        case .custom: "按你的喜好微调，自动为这部影片记住。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("观影预设", selection: Binding(get: { model.currentDepthEffect.preset }, set: {
                model.selectDepthPreset($0)
                if $0 == .custom { adjustments = true }
            })) {
                ForEach(DepthPreset.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(effectDescription).font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("更多调整", isExpanded: $adjustments) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("立体强度"); Spacer(); Text("\(Int(model.depthStrength * 100))%").monospacedDigit() }
                    Slider(value: Binding(get: { model.depthStrength }, set: { model.depthStrength = $0; model.depthPreset = .custom }), in: 0...1, onEditingChanged: { editing in
                        if !editing { model.savePicturePreferences() }
                    }).accessibilityLabel("立体强度")
                    Text("控制前后层次；设为 0 可对比平面画面。").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("出屏程度"); Spacer(); Text("\(Int(model.depthPopOut * 100))%").monospacedDigit() }
                    Slider(value: Binding(get: { model.depthPopOut }, set: { model.depthPopOut = $0; model.depthPreset = .custom }), in: 0...1, onEditingChanged: { editing in
                        if !editing { model.savePicturePreferences() }
                    }).accessibilityLabel("出屏程度")
                    Text("让前景更靠近你，并保留远景在屏幕后。").font(.caption).foregroundStyle(.secondary)
                    Toggle("比例保护", isOn: Binding(get: { model.depthProportionProtection }, set: {
                        model.depthProportionProtection = $0; model.depthPreset = .custom; model.savePicturePreferences()
                    }))
                    Text("减少脸部和四肢拉伸。出现重影时，可降低强度或出屏程度。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 16)
            }
            Divider()
            Button {
                model.library.saveDefaultDepthEffect(model.currentDepthEffect)
                savedDefault = true
            } label: {
                Label(savedDefault ? "已保存为新影片默认效果" : "设为新影片默认效果", systemImage: savedDefault ? "checkmark.circle.fill" : "bookmark")
            }.disabled(model.currentDepthEffect == model.library.defaultDepthEffect)
            Text(model.currentDepthEffect == model.library.defaultDepthEffect
                 ? "之后添加的影片开启 AI 立体时将使用此效果。已有影片保持原设置。"
                 : "只影响之后添加的影片；已有影片保留各自设置。")
                .font(.caption).foregroundStyle(.secondary)
            if model.currentDepthEffect != model.library.defaultDepthEffect {
                Button("恢复新影片默认效果") { model.applyDepthEffect(model.library.defaultDepthEffect) }
            }
        }.onChange(of: model.currentDepthEffect) { _, _ in savedDefault = false }
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
                if let notice = model.trackPreferenceNotice {
                    Section { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }
                if model.currentFilm != nil {
                    Section {
                        Text("音轨和字幕选择会记住到当前影片，包括关闭字幕。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            }.navigationTitle("字幕与声音")
                .toolbar {
                    if let done { ToolbarItem(placement: .confirmationAction) { Button("完成", action: done) } }
                }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]) { result in
            if case .success(let url) = result { model.importSubtitle(url) }
        }
    }
}


/// Shared order and hit targets for window and immersive playback.
struct PlaybackTransportButtons: View {
    @Bindable var model: PlayerModel
    var body: some View {
        HStack(spacing: 8) {
            Button("后退 10 秒", systemImage: "gobackward.10") { model.skip(-10); model.focus.reveal() }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(!model.isSeekable)
            Button(model.isPlaying ? "暂停" : "播放", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback(); model.focus.reveal()
            }.labelStyle(.iconOnly).keyboardShortcut(.space, modifiers: [])
                .frame(minWidth: 60, minHeight: 60).buttonStyle(.borderedProminent).disabled(model.request == nil)
            Button("快进 10 秒", systemImage: "goforward.10") { model.skip(10); model.focus.reveal() }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(!model.isSeekable)
        }
    }
}

struct PlaybackActionLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption)
        }.frame(minWidth: 42, minHeight: 52)
    }
}

struct PlaybackAdvancedSettings: View {
    @Bindable var model: PlayerModel
    let done: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                if model.request?.url.scheme?.lowercased() == "smb" {
                    Section {
                        Text("SMB 共享使用 VLC 播放。原生空间视频请通过本地文件或相册打开。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.request?.photoAssetIdentifier != nil {
                    Section {
                        Text("直接从相册播放。若需使用 VLC，请返回片库选择“从相册保存离线副本”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let request = model.request, !request.isSpatialVideo, request.photoAssetIdentifier == nil, request.url.scheme?.lowercased() != "smb" {
                    Section("播放兼容性") {
                        Picker("播放引擎", selection: Binding(get: { model.request?.engine ?? .native }, set: { model.switchEngine($0) })) {
                            Text("Apple 原生").tag(PlaybackEngine.native)
                            Text("VLCKit").tag(PlaybackEngine.vlc)
                        }.disabled(model.isClosing || model.isSwitchingEngine)
                    }
                }
                Section("观影控制") {
                    Toggle("专注观影", isOn: Binding(get: { model.library.focusViewing }, set: {
                        model.library.focusViewing = $0; model.focus.reveal()
                    }))
                    Text("播放时无操作 3 秒后隐藏控制。选中影片并捏合可唤回。").font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                Section("开发者") {
                    DisclosureGroup("实验对比") { MotionAlignmentComparison(model: model) }
                }
                #endif
            }.navigationTitle("播放设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回更多", action: done) } }
        }
    }
}
