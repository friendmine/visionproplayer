import SwiftUI

enum PlaybackSettingsPage: String {
    case picture = "画面", tracks = "字幕", cinema = "影院", more = "更多", advanced = "播放设置"
}

/// Both surfaces keep the page selector and content viewport in place. Only
/// the scrollable content changes; the cinema's exit stays outside this view.
struct PlaybackSettingsPanel: View {
    let model: PlayerModel
    @Binding var page: PlaybackSettingsPage?
    var enterCinema: (() async -> Void)?
    var leaveLibrary: (() async -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Picker("设置分类", selection: Binding(get: {
                page == .advanced ? .more : page ?? .picture
            }, set: { page = $0 })) {
                ForEach([PlaybackSettingsPage.picture, .tracks, .cinema, .more], id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                switch page {
                case .picture, .none:
                    PictureSettings(model: model)
                case .tracks:
                    TrackSettings(model: model)
                case .cinema:
                    ScrollView {
                        if let enterCinema { CinemaSettings(model: model, enter: enterCinema) }
                        else {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("影院设置").font(.title2.bold())
                                Toggle("暗色环境", isOn: Binding(get: { model.library.darkCinema }, set: { model.library.darkCinema = $0 }))
                                ScreenAdjustments(model: model)
                            }
                        }
                    }
                case .more:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let film = model.currentFilm {
                                Button(film.favorite ? "取消收藏" : "收藏影片", systemImage: film.favorite ? "heart.fill" : "heart") {
                                    model.library.update(film.id) { $0.favorite.toggle() }
                                }
                            }
                            Button("从头播放", systemImage: "arrow.counterclockwise") { page = nil; model.restart() }
                            Button("播放设置", systemImage: "gearshape") { page = .advanced }
                            if let leaveLibrary {
                                Button("返回片库", systemImage: "square.grid.2x2") { page = nil; Task { await leaveLibrary() } }
                            }
                            if model.currentFilm?.title.hasPrefix("Big Buck Bunny") == true || model.request?.url.lastPathComponent.hasPrefix("BBB-") == true {
                                Text("Big Buck Bunny © 2008 Blender Foundation · CC BY 3.0").font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .advanced:
                    PlaybackAdvancedSettings(model: model, done: { page = .more })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: page, initial: true) { _, destination in
            if destination == .tracks { model.loadTracks() }
        }
    }
}

struct PlaybackSettingsButtons: View {
    let model: PlayerModel
    @Binding var page: PlaybackSettingsPage?
    var body: some View {
        Button { page = .picture } label: {
            VStack(spacing: 3) {
                Label("画面", systemImage: "view.3d").font(.callout)
                Text(model.pictureTitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(width: 84, height: 52)
        }.accessibilityLabel("画面").accessibilityValue(model.pictureTitle)
            .disabled(model.request == nil)
        Button { page = .tracks } label: { PlaybackActionLabel("字幕", symbol: "captions.bubble") }
            .accessibilityLabel("字幕与声音").disabled(model.request == nil)
        Button { page = .cinema } label: { PlaybackActionLabel("影院", symbol: "vision.pro") }
            .disabled(model.request == nil)
        Button { page = .more } label: { PlaybackActionLabel("更多", symbol: "ellipsis") }
    }
}


// Keep play/pause and seeking directly reachable when the full set of labels
// cannot fit. The compact settings button opens the same four-page panel.
struct AdaptivePlaybackControls: View {
    let model: PlayerModel
    @Binding var page: PlaybackSettingsPage?
    @ScaledMetric(relativeTo: .body) private var fullRowWidth: CGFloat = 575

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                PlaybackTransportButtons(model: model)
                Spacer(minLength: 4)
                if geometry.size.width >= fullRowWidth {
                    PlaybackSettingsButtons(model: model, page: $page)
                } else {
                    Button { page = .picture } label: {
                        VStack(spacing: 3) {
                            Label("观看设置", systemImage: "slider.horizontal.3")
                            Text(model.pictureTitle).font(.caption)
                        }.frame(minHeight: 52)
                    }.accessibilityLabel("观看设置").accessibilityValue(model.pictureTitle)
                }
            }.frame(maxHeight: .infinity)
        }
    }
}
