import Foundation

@main struct NetworkSourceTests {
    static func main() throws {
        let root = try NetworkServer.validatedRoot(" NAS.local/共享 电影 ")
        let server = NetworkServer(name: "Test", address: root.absoluteString, requiresLogin: true)
        assert(root.host == "nas.local")
        let path = ["子目录", "A #1 & 100%.mp4"]
        let file = try server.url(for: path)
        assert(server.childPath(file, parent: ["子目录"]) == path)
        let folder = try server.url(for: ["子目录"], directory: true)
        assert(server.childPath(folder, parent: []) == ["子目录"])
        for address in ["http://nas.local/share", "smb://nas%40other/share", "smb://user:pass@nas.local/share", "smb://nas.local/share?password=x", "smb://nas.local/share#x", "smb://nas.local:99999/share", "smb://nas.local/share/../private", "smb://nas.local/share/%2e%2e/private", "smb://nas.local/share/%00"] {
            do { _ = try NetworkServer.validatedRoot(address); assertionFailure("Accepted invalid address") } catch {}
        }
        assert(server.childPath(URL(string: "smb://other.local/共享%20电影/video.mp4")!, parent: []) == nil)
        assert(server.childPath(URL(string: "smb://nas.local/共享%20电影/../secret.mp4")!, parent: []) == nil)
        assert(server.childPath(URL(string: "smb://u:p@nas.local/共享%20电影/video.mp4")!, parent: []) == nil)
        assert(server.childPath(URL(string: "smb://nas.local/共享%20电影/sub/video.mp4")!, parent: []) == nil)
        let ipv6 = try NetworkServer.validatedRoot("smb://[::1]:1445/share")
        assert(ipv6.port == 1445)
        assert(NetworkEntry(path: ["MOVIE.MKV"], isDirectory: false).isVideo)
        assert(!NetworkEntry(path: ["readme.txt"], isDirectory: false).isVideo)
        let json = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(NetworkServer.self, from: json)
        assert(decoded == server)
        let text = String(decoding: json, as: UTF8.self)
        assert(!text.contains("password") && !text.contains("username"))
        assert(PlaybackEngine.automatic.resolved(for: file) == .vlc)
        assert(PlaybackEngine.native.resolved(for: file) == .vlc)
        print("PASS: SMB URL validation, Unicode/space/special names, child boundaries, IPv6, credential-free records and engine routing")
    }
}
