import Foundation

@main struct NetworkStoreTests {
    @MainActor static func main() throws {
        let root = URL.temporaryDirectory.appending(path: "network-store-test-\(UUID())")
        let keychain = NetworkCredentialStore()
        let id = UUID()
        defer { try? keychain.save(nil, for: id); try? FileManager.default.removeItem(at: root) }
        let store = NetworkServerStore(root: root)
        let password = UUID().uuidString
        let login = NetworkCredentials(username: "fixture-user", password: password, domain: "fixture-domain")
        var server = NetworkServer(id: id, name: "Test", address: "smb://nas.example/Movies/", requiresLogin: true)
        try store.save(server, login: login)
        let data = try Data(contentsOf: root.appending(path: "servers.json"))
        let text = String(decoding: data, as: UTF8.self)
        assert(!text.contains(password) && !text.contains(login.username) && !text.contains(login.domain))
        let reopened = NetworkServerStore(root: root)
        assert(reopened.servers == [server])
        let saved = try reopened.login(for: server)
        assert(saved == login)
        let source = try reopened.source(serverID: id, path: ["电影 #1.mp4"])
        assert(source.credentials == login && source.url.user == nil && source.url.password == nil)
        // Persistence failure must not replace existing Keychain credentials.
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        do { try store.save(server, login: NetworkCredentials(username: "replacement", password: "replacement", domain: "")); assertionFailure("Expected failed save") } catch {}
        let rolledBack = try keychain.load(id)
        assert(rolledBack == login)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server.requiresLogin = false
        try store.save(server, login: nil)
        let cleared = try keychain.load(id)
        assert(cleared == nil)
        try store.remove(server)
        assert(NetworkServerStore(root: root).servers.isEmpty)
        try Data("invalid-json".utf8).write(to: root.appending(path: "servers.json"))
        let broken = NetworkServerStore(root: root)
        assert(broken.error != nil)
        do { try broken.save(server, login: nil); assertionFailure("Expected corrupt store protection") } catch {}
        print("PASS: Keychain round trip, credential-free JSON/URL, reload, rollback after disk failure, guest switch, removal and corrupt-store protection")
    }
}
