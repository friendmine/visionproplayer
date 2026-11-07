import SwiftUI

struct NetworkSourcesView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NetworkServer?
    @State private var removing: NetworkServer?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("添加 NAS 的 SMB 地址，浏览共享目录后直接播放。影片不下载到 App；账户和密码保存在系统钥匙串。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.networkServers.servers.isEmpty {
                    ContentUnavailableView("添加你的 NAS", systemImage: "externaldrive.connected.to.line.below", description: Text("例如 smb://nas.local/Movies，也可填写 NAS 的局域网 IP 地址。"))
                }
                ForEach(model.networkServers.servers) { server in
                    NavigationLink {
                        NetworkDirectoryView(model: model, serverID: server.id, played: { dismiss() })
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if server.requiresLogin { Image(systemName: "lock").foregroundStyle(.secondary) }
                        }
                    }.contextMenu {
                        Button("编辑服务器", systemImage: "pencil") { editing = server }
                        Button("移除服务器", systemImage: "trash", role: .destructive) { removing = server }
                    }
                }
                if let message = error ?? model.networkServers.error { Text(message).foregroundStyle(.orange) }
            }
            .navigationTitle("局域网服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("添加服务器", systemImage: "plus") { editing = NetworkServer(name: "", address: "smb://", requiresLogin: true) }
                }
            }
        }.frame(width: 760, height: 650)
            .sheet(item: $editing) { NetworkServerEditor(store: model.networkServers, server: $0) }
            .confirmationDialog("移除服务器及保存的登录信息？NAS 文件不会删除，片库中的影片记录会保留，但需要重新添加来源才能播放。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除服务器", role: .destructive) {
                    if let removing {
                        do { try model.networkServers.remove(removing) } catch { self.error = error.localizedDescription }
                    }
                    removing = nil
                }
            }
    }
}

private struct NetworkServerEditor: View {
    let store: NetworkServerStore
    let server: NetworkServer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var guest = false
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称，例如家里的 NAS", text: $name)
                    TextField("smb://nas.local/Movies", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("可填写服务器根地址，也可直接填写共享文件夹路径。支持 SMB 2/3，不需要把用户名或密码放进地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("登录") {
                    Toggle("访客访问", isOn: $guest)
                    if !guest {
                        TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("密码", text: $password)
                        TextField("域 / 工作组（可选）", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text("登录信息只保存在本设备钥匙串中。首次连接需允许本地网络访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }.navigationTitle(store.server(server.id) == nil ? "添加服务器" : "编辑服务器")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
                }
        }.frame(width: 580, height: 650).onAppear {
            name = server.name; address = server.address; guest = !server.requiresLogin
            if store.server(server.id) != nil, !guest {
                do {
                    let login = try store.login(for: server)
                    username = login.username; password = login.password; domain = login.domain
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save() {
        do {
            let url = try NetworkServer.validatedRoot(address)
            var edited = server; edited.name = name; edited.address = url.absoluteString; edited.requiresLogin = !guest
            let login = guest ? nil : NetworkCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, domain: domain.trimmingCharacters(in: .whitespacesAndNewlines))
            try store.save(edited, login: login)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct NetworkDirectoryView: View {
    @Bindable var model: PlayerModel
    let serverID: UUID
    let played: () -> Void
    @State private var directory = NetworkDirectory()
    @State private var search = ""
    @State private var editing: NetworkServer?
    @State private var error: String?
    private var server: NetworkServer? { model.networkServers.server(serverID) }
    private var entries: [NetworkEntry] { directory.entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("上一级", systemImage: "arrow.up") { load(Array(directory.path.dropLast())) }.disabled(directory.path.isEmpty)
                Text(directory.path.isEmpty ? "共享目录" : directory.path.joined(separator: " / "))
                    .font(.caption).lineLimit(2)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { load(directory.path) }
            }.padding(.horizontal)
            if directory.loading {
                VStack(spacing: 18) {
                    ProgressView("正在读取共享目录…")
                    Button("取消连接") { directory.cancelLoading() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = error ?? directory.error {
                ContentUnavailableView {
                    Label("无法打开共享", systemImage: "wifi.exclamationmark")
                } description: { Text(message) } actions: {
                    Button("重试") { load(directory.path) }
                    Button("编辑服务器") { editing = server }
                }
            } else if entries.isEmpty {
                ContentUnavailableView("没有找到影片", systemImage: "folder", description: Text(search.isEmpty ? "此目录没有文件夹或支持的视频文件。" : "试试其他关键词。"))
            } else {
                List(entries) { entry in
                    Button {
                        if entry.isDirectory { load(entry.path) }
                        else { play(entry) }
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "play.rectangle")
                            Text(entry.name).lineLimit(2)
                            Spacer()
                            if entry.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(server?.name ?? "服务器已移除")
            .searchable(text: $search, prompt: "搜索当前目录")
            .toolbar { Button("服务器设置", systemImage: "gearshape") { editing = server } }
            .sheet(item: $editing, onDismiss: { load([]) }) { NetworkServerEditor(store: model.networkServers, server: $0) }
            .task { load([]) }
            .onDisappear { directory.cancel() }
    }
    private func load(_ path: [String]) {
        error = nil; search = ""
        guard let server else { error = NetworkSourceError.missingServer.localizedDescription; return }
        directory.load(server: server, path: path, store: model.networkServers)
    }
    private func play(_ entry: NetworkEntry) {
        guard let server else { return }
        do {
            let film = try model.library.addNetworkFilm(server: server, path: entry.path)
            model.openFilm(film); played()
        } catch { self.error = error.localizedDescription }
    }
}
