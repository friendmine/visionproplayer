import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: PlayerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoImporter = PhotoVideoImporter()
    @State private var settings = false
    @State private var linkSheet = false
    @State private var editingLink: LibraryFilm?
    @State private var relocating: UUID?
    @State private var search = ""
    @State private var filter = "全部"
    @State private var renaming: LibraryFilm?
    @State private var removing: LibraryFilm?

    private var visibleFilms: [LibraryFilm] {
        model.library.recent.filter {
            (filter != "收藏" || $0.favorite) && (filter != "网络" || $0.isNetwork)
            && (search.isEmpty || $0.title.localizedStandardContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if model.showingPlayer {
                    PlayerScreen(model: model)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if model.library.films.isEmpty {
                                ContentUnavailableView {
                                    Label("你的私人影院", systemImage: "film.stack")
                                } description: {
                                    Text("打开一部影片开始观看。进度和画面设置会为你保留。")
                                } actions: {
                                    Button("打开影片", systemImage: "folder") { importing = true }.buttonStyle(.borderedProminent)
                                    Button("从相册导入", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                                    Button("播放视频链接", systemImage: "link") { editingLink = nil; linkSheet = true }
                                }.frame(minHeight: 380)
                            } else {
                                if search.isEmpty, filter == "全部", let film = model.library.recent.first(where: { $0.resumable }) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text("继续观看").font(.title2.bold())
                                        Button { model.openFilm(film) } label: {
                                            HStack(spacing: 24) {
                                                FilmPoster(film: film, library: model.library).frame(width: 290, height: 165)
                                                VStack(alignment: .leading, spacing: 12) {
                                                    Text(film.title).font(.title2).lineLimit(2)
                                                    Text("上次看到 \(PlayerModel.clock(film.position))").foregroundStyle(.secondary)
                                                    ProgressView(value: min(1, film.position / max(1, film.duration)))
                                                    Label("继续播放", systemImage: "play.fill")
                                                }.padding(.trailing, 24)
                                                Spacer(minLength: 0)
                                            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                                        }.buttonStyle(.plain)
                                    }
                                }
                                HStack {
                                    Text(filter == "全部" ? (model.library.hasWatchHistory ? "最近打开" : "我的片库") : filter).font(.title2.bold())
                                    Spacer()
                                    Picker("片库分类", selection: $filter) {
                                        ForEach(["全部", "收藏", "网络"], id: \.self) { Text($0) }
                                    }.pickerStyle(.segmented).frame(width: 300)
                                }
                                if visibleFilms.isEmpty {
                                    ContentUnavailableView(search.isEmpty ? "这里还没有影片" : "没有找到影片", systemImage: search.isEmpty ? "film" : "magnifyingglass")
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 22)], spacing: 24) {
                                    ForEach(visibleFilms) { film in
                                        Button { model.openFilm(film) } label: {
                                            VStack(alignment: .leading, spacing: 9) {
                                                FilmPoster(film: film, library: model.library).frame(height: 150)
                                                HStack {
                                                    Text(film.title).lineLimit(1).font(.headline)
                                                    if film.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                                                }
                                                Text("\(film.isSpatialVideo == true ? "空间 3D" : (film.preferences.layout.isStereo ? "3D" : "2D")) · \(film.sourceDescription)")
                                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                if film.duration > 0 { ProgressView(value: min(1, film.position / film.duration)).tint(.secondary) }
                                            }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                                        }.buttonStyle(.plain)
                                            .contextMenu {
                                                Button("从头播放", systemImage: "play") { model.openFilm(film, fromStart: true) }
                                                Button(film.favorite ? "取消收藏" : "收藏", systemImage: film.favorite ? "heart.slash" : "heart") { model.library.update(film.id) { $0.favorite.toggle() } }
                                                Button("重命名", systemImage: "pencil") { renaming = film }
                                                if film.isNetwork {
                                                    Button("编辑网络来源", systemImage: "link") { editingLink = film; linkSheet = true }
                                                } else if film.photoFile == nil {
                                                    Button("重新定位文件", systemImage: "folder") { relocating = film.id; importing = true }
                                                }
                                                Button("从片库移除", systemImage: "minus.circle", role: .destructive) { removing = film }
                                            }
                                            .task { model.library.makeThumbnail(for: film) }
                                    }
                                }
                            }
                            if let error = model.library.error { Text(error).foregroundStyle(.orange).font(.caption) }
                        }.padding(28)
                    }
                    .navigationTitle("Vision Player")
                    .searchable(text: $search, prompt: "搜索影片")
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button("设置", systemImage: "gearshape") { settings = true }
                            Menu {
                                Button("打开文件", systemImage: "folder") { relocating = nil; importing = true }
                                Button("从相册导入", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                                Button("视频链接", systemImage: "link") { editingLink = nil; linkSheet = true }
                            } label: { Label("打开影片", systemImage: "plus") }
                        }
                    }
                }
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            photoSelection = nil
            photoImporter.begin(item, model: model)
        }
        .sheet(isPresented: Binding(get: { photoImporter.isImporting }, set: { if !$0 { photoImporter.cancel() } })) {
            VStack(spacing: 24) {
                Text("正在导入视频").font(.title2)
                if let fraction = photoImporter.fraction { ProgressView(value: fraction).frame(width: 320) }
                else { ProgressView() }
                Text("iCloud 视频可能需要先下载。导入后会在 App 中保留一份副本，不改动相册原视频。").foregroundStyle(.secondary)
                Button("取消") { photoImporter.cancel() }
            }.padding(32).frame(width: 480)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data]) { result in
            defer { relocating = nil }
            switch result {
            case .success(let url):
                if let id = relocating {
                    do { try model.library.relocate(id, to: url); if let film = model.library.film(id) { model.openFilm(film) } }
                    catch { model.errorMessage = error.localizedDescription }
                } else { model.importFilm(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $settings) { SettingsView(model: model) { settings = false } }
        .sheet(isPresented: $linkSheet) { NetworkSourceSheet(model: model, existing: editingLink) }
        .sheet(item: $renaming) { film in RenameFilmSheet(library: model.library, film: film) }
        .confirmationDialog(removing?.photoFile != nil ? "移除影片及 App 内导入副本？相册原视频不会删除。" : "从片库移除？原始影片文件不会被删除。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除记录", role: .destructive) { if let film = removing { model.library.remove(film.id) }; removing = nil }
        }
        .alert("无法打开影片", isPresented: Binding(get: { model.errorMessage != nil && !model.showingPlayer }, set: { if !$0 { model.errorMessage = nil } })) {
            if let id = model.missingFilmID { Button("重新定位文件") { relocating = id; importing = true } }
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !model.cinemaActive { model.pauseForBackground(); model.checkpoint() }
        }
        .onDisappear { photoImporter.cancel(); if !model.cinemaActive { model.pauseForBackground(); model.checkpoint() } }
        .task { await model.runSmokeTestIfRequested() }
    }
}

struct FilmPoster: View {
    let film: LibraryFilm
    let library: MediaLibrary
    var body: some View {
        let _ = library.thumbnailRevision
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.4), .black.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = posterImage {
                    let aspect = image.size.width / image.size.height * (film.preferences.layout == .halfSBS ? 2 : (film.preferences.layout == .halfOU ? 0.5 : 1))
                    Image(uiImage: image).resizable().aspectRatio(aspect, contentMode: .fill)
                } else {
                    Image(systemName: film.isNetwork ? "network" : "film").font(.system(size: 38)).foregroundStyle(.white.opacity(0.65))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 15))
        }
    }
    private var posterImage: UIImage? {
        guard let image = UIImage(contentsOfFile: library.thumbnailURL(film.id).path) else { return nil }
        guard film.preferences.layout.isStereo, let source = image.cgImage,
              let left = source.cropping(to: film.preferences.layout.eyeRegions(width: source.width, height: source.height).left) else { return image }
        return UIImage(cgImage: left)
    }
}

struct RenameFilmSheet: View {
    let library: MediaLibrary
    let film: LibraryFilm
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("重命名影片").font(.title2)
            TextField("影片名称", text: $title).textFieldStyle(.roundedBorder)
            Text("只修改片库中的名称，不更改原文件。 ").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { library.update(film.id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }; dismiss() }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(32).frame(width: 480).onAppear { title = film.title }
    }
}

struct NetworkSourceSheet: View {
    @Bindable var model: PlayerModel
    let existing: LibraryFilm?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(existing == nil ? "视频链接" : "编辑网络来源").font(.title2)
            TextField("https://…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            TextField("名称（可选）", text: $name).textFieldStyle(.roundedBorder)
            Text("输入视频直链或 HLS 地址。局域网文件也可通过系统“文件”中的服务器连接打开。").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("保存到片库") { save(play: false) }
                Button("播放") { save(play: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(32).frame(width: 620)
            .onAppear { address = existing?.location ?? ""; name = existing?.title ?? "" }
    }
    private func save(play: Bool) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else {
            error = "请输入有效的 HTTP / HTTPS 视频地址；请勿在地址中填写账户密码。"; return
        }
        do {
            let film: LibraryFilm
            if let existing {
                model.library.update(existing.id) {
                    if $0.location != url.absoluteString { $0.position = 0; $0.duration = 0 }
                    $0.location = url.absoluteString; $0.title = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.lastPathComponent
                }
                film = model.library.film(existing.id)!
            } else { film = try model.library.add(url, title: name) }
            dismiss(); if play { model.openFilm(film) }
        } catch { self.error = error.localizedDescription }
    }
}
