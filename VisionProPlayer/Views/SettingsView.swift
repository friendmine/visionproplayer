import SwiftUI

struct SettingsView: View {
    @Bindable var model: PlayerModel
    let close: () -> Void
    @State private var confirmingHistoryClear = false
    @State private var historyCleared = false
    @State private var historyError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("观看") {
                    Toggle("专注观影", isOn: Binding(get: { model.library.focusViewing }, set: { model.library.focusViewing = $0; model.focus.reveal() }))
                    Text("播放时无操作 3 秒后收起控制；轻点画面恢复。字幕保留，暂停和调节时控制保持显示。").font(.caption).foregroundStyle(.secondary)
                    Toggle("自动续播", isOn: Binding(get: { model.library.resumePlayback }, set: { model.library.resumePlayback = $0 }))
                    Text("画面格式、AI 立体强度和眼别按影片保存。新影片默认不开启 AI 转换。").font(.caption).foregroundStyle(.secondary)
                }
                Section("空间影院") {
                    Toggle("暗色环境", isOn: Binding(get: { model.library.darkCinema }, set: { model.library.darkCinema = $0 }))
                    Text("关闭时保留现实环境。进入影院后可以调整屏幕尺寸和距离。").font(.caption).foregroundStyle(.secondary)
                }
                Section("观看历史") {
                    Button("清除观看历史", systemImage: "clock.arrow.circlepath", role: .destructive) {
                        confirmingHistoryClear = true
                    }.disabled(!model.library.hasWatchHistory)
                    Text(model.library.hasWatchHistory
                         ? "清除最近观看记录和续播进度。保留片库影片、收藏及影片设置。"
                         : (historyCleared ? "观看历史已清除。再次打开影片将从头播放。" : "暂无观看历史。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("Vision Player", value: "0.2 · 预览版")
                    NavigationLink("开源许可与素材署名") { LicenseView() }
                }
                #if DEBUG
                Section("开发者") {
                    NavigationLink("诊断与测试") { DiagnosticsView(model: model, close: close) }
                }
                #endif
            }.navigationTitle("设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) } }
        }.frame(width: 640, height: 610)
        .confirmationDialog("清除全部观看历史？", isPresented: $confirmingHistoryClear, titleVisibility: .visible) {
            Button("清除观看历史", role: .destructive) {
                do { try model.library.clearWatchHistory(); historyCleared = true }
                catch { historyError = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将清除最近观看记录和所有续播进度，无法撤销。片库影片、收藏、相册副本和影片设置都会保留。")
        }
        .alert("未能清除观看历史", isPresented: Binding(get: { historyError != nil }, set: { if !$0 { historyError = nil } })) {
            Button("好", role: .cancel) { historyError = nil }
        } message: { Text(historyError ?? "请稍后重试。") }
    }
}

struct LicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("VLCKit / libVLC · VideoLAN").font(.headline)
                Link("LGPL 许可与源码", destination: URL(string: "https://github.com/videolan/vlckit")!)
                Text("Big Buck Bunny © 2008 Blender Foundation / www.bigbuckbunny.org。Sunflower 版：Janus B. Kristensen，2013。演示片经过剪辑、缩放与格式调整；2D 演示取原片左眼画面。")
                Link("Creative Commons Attribution 3.0", destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!)
                Text("Depth Anything V2 Small · Apache 2.0").font(.headline)
                Text("Lihe Yang、Bingyi Kang、Zilong Huang、Xiaogang Xu、Jiashi Feng、Hengshuang Zhao。使用 Apple 提供的 Core ML 转换版本。")
                if let url = Bundle.main.url(forResource: "DepthAnythingV2-License", withExtension: "txt"), let license = try? String(contentsOf: url, encoding: .utf8) { Text(license).font(.caption).textSelection(.enabled) }
            }.padding(28)
        }.navigationTitle("许可与署名")
    }
}

#if DEBUG
struct DiagnosticsView: View {
    @Bindable var model: PlayerModel
    let close: () -> Void
    var body: some View {
        Form {
            Section("当前状态") {
                Text("引擎：\(model.request?.engine.title ?? "未播放")")
                Text("\(model.frameSize) · 提交 \(model.renderedFrames) 帧")
                Text("深度 \(model.depthInferenceMS, specifier: "%.1f") ms · \(model.depthDisplayFPS, specifier: "%.1f") fps")
                Toggle("左右眼检查", isOn: $model.eyeCheck)
                Picker("调试引擎（仅用于下次调试打开）", selection: $model.engineChoice) { ForEach(PlaybackEngine.allCases) { Text($0.title).tag($0) } }
            }
            Section("片库演示") {
                Button("添加 Big Buck Bunny 2D 和 3D 到片库") {
                    for (name, title) in [("BBB-HEVC-2D-30s.mp4", "Big Buck Bunny"), ("BBB-SBS-60s.mp4", "Big Buck Bunny 3D")] {
                        let url = URL.documentsDirectory.appending(path: name)
                        if FileManager.default.fileExists(atPath: url.path) { _ = try? model.library.add(url, title: title) }
                    }
                    close()
                }
            }
            Section("内置测试") {
                sample("2D · 原生", "Sample2D", "mp4", .flat, .native)
                sample("MKV · VLC", "SampleMKV", "mkv", .flat, .vlc)
                sample("SBS · 原生", "SampleSBS", "mp4", .fullSBS, .native)
                sample("SBS · VLC", "SampleSBS", "mkv", .fullSBS, .vlc)
            }
            Section("H.265 / Half SBS") {
                ForEach(CompatibilitySample.allCases) { sample in
                    Button(sample.title) { play(sample.url, sample.layout, sample.engine) }
                }
            }
            Section("左右眼与出屏对照") {
                Button("播放出屏对照（无 AI）") {
                    let url = URL.documentsDirectory.appending(path: "StereoReference.mp4")
                    if FileManager.default.fileExists(atPath: url.path) { play(url, .fullSBS, .native) }
                }
                Text("单眼确认 LEFT / RIGHT；双眼比较金色圆盘、白色参照框和青色圆盘的前后位置。").font(.caption)
            }
            Section("AI 立体") {
                Button("2D 转 3D · 原生") { play(CompatibilitySample.hevcMP4.url, .flat, .native, depth: true) }
                Button("2D 转 3D · VLC") { play(CompatibilitySample.hevcMKV.url, .flat, .vlc, depth: true) }
                ForEach([PlaybackEngine.native, .vlc]) { engine in
                    let url = URL.documentsDirectory.appending(path: engine == .vlc ? "BBB-Motion-2D-30s.mkv" : "BBB-Motion-2D-30s.mp4")
                    if FileManager.default.fileExists(atPath: url.path) {
                        Button("运动与切镜头 · \(engine.title)") { play(url, .flat, engine, depth: true) }
                    }
                }
            }
        }.navigationTitle("诊断与测试")
    }
    private func sample(_ title: String, _ name: String, _ ext: String, _ layout: StereoLayout, _ engine: PlaybackEngine) -> some View {
        Button(title) { if let url = Bundle.main.url(forResource: name, withExtension: ext) { play(url, layout, engine) } }
    }
    private func play(_ url: URL, _ layout: StereoLayout, _ engine: PlaybackEngine, depth: Bool = false) {
        close(); model.openSample(url, layout: layout, engine: engine, convert2D: depth)
    }
}
#endif
