import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: PlayerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var urlText = ""
    @State private var isDragging = false
    @State private var seekValue = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vision Player Lab").font(.largeTitle.bold())
                    Text("2D · MKV · SBS 3D 播放验证").foregroundStyle(.secondary)
                }
                Spacer()
                Button { importing = true } label: { Label("打开文件", systemImage: "folder") }
                    .disabled(model.isClosing)
            }
            HStack(spacing: 12) {
                sampleButton("2D 测试", icon: "play.rectangle", name: "Sample2D", ext: "mp4", layout: .flat, engine: .native)
                sampleButton("MKV 测试", icon: "film.stack", name: "SampleMKV", ext: "mkv", layout: .flat, engine: .vlc)
                sampleButton("SBS · 原生", icon: "vision.pro", name: "SampleSBS", ext: "mp4", layout: .fullSBS, engine: .native)
                sampleButton("SBS · VLC", icon: "vision.pro", name: "SampleSBS", ext: "mkv", layout: .fullSBS, engine: .vlc)
                Menu("真实 3D 短片") {
                    Button("Big Buck Bunny · 原生") { openDownloadedStereo(engine: .native) }
                    Button("Big Buck Bunny · VLC") { openDownloadedStereo(engine: .vlc) }
                }.disabled(model.isClosing)
            }
            HStack {
                Picker("播放引擎", selection: $model.engineChoice) {
                    ForEach(PlaybackEngine.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 250)
                Picker("视频格式", selection: $model.layoutChoice) {
                    ForEach(StereoLayout.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 360)
                Toggle("交换左右眼", isOn: $model.swapEyes).toggleStyle(.button)
                    .disabled(model.eyeCheck)
                Spacer()
            }
            if model.request?.layout.isStereo == true {
                HStack {
                    Toggle("左右眼检查", isOn: $model.eyeCheck).toggleStyle(.button)
                    Text(model.eyeCheck
                         ? "分别闭眼检查：左眼应为纯红，右眼应为纯蓝；绿色表示单眼渲染。关闭检查后恢复视频。"
                         : (model.request?.url.lastPathComponent.hasPrefix("BBB-") == true
                            ? "Big Buck Bunny 立体片段 · Full SBS · 60 秒。左右眼检查可单独验证眼别。"
                            : "立体演示：金球在近处、青球在中间、紫球在远处。左右眼检查可单独验证眼别。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("https://… 视频地址", text: $urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("打开地址") { openURL() }.disabled(model.isClosing || urlText.isEmpty)
            }
            playbackSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 260)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            if let request = model.request {
                HStack {
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Text(PlayerModel.clock(model.elapsed)).monospacedDigit()
                    Slider(value: $seekValue, in: 0...1, onEditingChanged: { editing in
                        isDragging = editing
                        if !editing { model.seek(to: seekValue) }
                    }).disabled(!model.isSeekable)
                    Text(PlayerModel.clock(model.duration)).monospacedDigit()
                    Button("停止") { model.stop() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.url.lastPathComponent.isEmpty ? "网络视频" : request.url.lastPathComponent)
                        .lineLimit(1).font(.headline)
                    if request.url.lastPathComponent.hasPrefix("BBB-") {
                        Text("© 2008 Blender Foundation · www.bigbuckbunny.org · CC BY 3.0")
                        Text("Sunflower 立体版：Janus B. Kristensen，2013。测试版剪辑、缩放并重排为 SBS。")
                    }
                    Text("\(request.engine.title) · \(request.layout.title) · \(model.stateText)")
                    if request.layout.isStereo {
                        Text("\(model.frameSize) · 已提交 \(model.renderedFrames) 帧")
                        Text(request.engine == .vlc
                            ? "实验路径：VLC 软件解码 → SDR BGRA → 左右眼纹理，输出最长边上限 1920。"
                            : "实验路径：AVPlayer 视频帧 → SDR 左右眼纹理。立体效果需真机确认。")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.isClosing ? "正在释放播放器…" : "引擎与格式选择应用于下次打开。测试按钮使用预设配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage ?? model.rendererError {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
        }
        .padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $model.nativePresented, onDismiss: {
            // Dismissing native full-screen playback stops audio as well.
            if model.request?.engine == .native && model.request?.layout == .flat { model.stop() }
        }) {
            if let player = model.nativePlayer {
                ZStack(alignment: .topLeading) {
                    NativePlayerView(player: player)
                    Button("返回片库", systemImage: "chevron.backward") { model.nativePresented = false }
                        .padding(24)
                }
            }
        }
        .onChange(of: model.progress) { _, value in if !isDragging { seekValue = value } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.pauseForBackground() } }
        .onDisappear { if !model.nativePresented { model.stop() } }
        .task { await model.runSmokeTestIfRequested() }
    }

    @ViewBuilder private var playbackSurface: some View {
        if let request = model.request {
            if request.layout.isStereo {
                StereoPlayerView(model: model, request: request).id(request.id)
                    .padding(20)
            } else if request.engine == .vlc {
                VLCPlayerView(model: model).id(request.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 50))
                    Button("打开系统播放器") { model.nativePresented = true }
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "vision.pro").font(.system(size: 54)).foregroundStyle(.cyan)
                Text("从一个短测试片开始").font(.title2)
                Text("2D 片含彩条和音调；SBS 片展示近、中、远三层球体。")
                    .foregroundStyle(.secondary)
                Text("当前是验证工程，尚未完成真机格式兼容认证。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }

    private func sampleButton(_ title: String, icon: String, name: String, ext: String,
                              layout: StereoLayout, engine: PlaybackEngine) -> some View {
        Button {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                model.errorMessage = "缺少内置测试片，请运行 Scripts/generate_samples.sh 后重新编译。"
                return
            }
            model.layoutChoice = layout; model.engineChoice = engine
            model.open(url, layout: layout, engine: engine)
        } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity) }
            .disabled(model.isClosing)
    }

    private func openDownloadedStereo(engine: PlaybackEngine) {
        let ext = engine == .vlc ? "mkv" : "mp4"
        let url = URL.documentsDirectory.appending(path: "BBB-SBS-60s.\(ext)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.errorMessage = "测试短片尚未传入此设备。请先将 BBB-SBS-60s.\(ext) 放入本 App 的 Documents。"
            return
        }
        model.eyeCheck = false
        model.swapEyes = false
        model.layoutChoice = .fullSBS
        model.engineChoice = engine
        model.open(url, layout: .fullSBS, engine: engine)
    }

    private func openURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            model.errorMessage = "请输入有效的 HTTP 或 HTTPS 视频地址。"
            return
        }
        model.open(url)
    }
}
