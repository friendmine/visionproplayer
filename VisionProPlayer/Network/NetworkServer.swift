import Foundation

struct NetworkServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var requiresLogin = false

    var rootURL: URL { URL(string: address)! } // Created only through validatedRoot.
    var hostLabel: String { rootURL.host ?? "SMB" }

    static func validatedRoot(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var parts = URLComponents(string: value.contains("://") ? value : "smb://" + value),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              !host.contains(where: { $0.isWhitespace }),
              !host.contains(where: { "@/\\#?%".contains($0) }),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NetworkSourceError.invalidAddress }
        let components = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy(validComponent) else { throw NetworkSourceError.invalidAddress }
        parts.scheme = "smb"; parts.host = host.lowercased()
        parts.path = "/" + components.joined(separator: "/") + (components.isEmpty ? "" : "/")
        guard let url = parts.url else { throw NetworkSourceError.invalidAddress }
        return url
    }

    static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func url(for path: [String], directory: Bool = false) throws -> URL {
        guard path.allSatisfy(Self.validComponent) else { throw NetworkSourceError.invalidAddress }
        let result = path.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: false) }
        return directory ? result.appendingPathComponent("", isDirectory: true) : result
    }

    /// Accept only direct children of the requested directory on this server.
    /// Directory replies never authorize another host, parent traversal or URL credentials.
    func childPath(_ url: URL, parent: [String]) -> [String]? {
        guard url.scheme?.lowercased() == "smb", url.host?.lowercased() == rootURL.host?.lowercased(),
              (url.port ?? 445) == (rootURL.port ?? 445), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let root = rootURL.path.split(separator: "/").map(String.init)
        let child = url.path.split(separator: "/").map(String.init)
        guard child.allSatisfy(Self.validComponent), child.count == root.count + parent.count + 1,
              Array(child.prefix(root.count + parent.count)) == root + parent else { return nil }
        return Array(child.dropFirst(root.count))
    }
}

struct NetworkCredentials: Codable, Equatable {
    var username: String
    var password: String
    var domain: String
    static let guest = NetworkCredentials(username: "guest", password: "", domain: "")
    var dictionary: [String: String] { ["smb-user": username, "smb-pwd": password, "smb-domain": domain] }
    var valid: Bool { !username.isEmpty && ![username, password, domain].contains { $0.contains("\0") } }
}

struct NetworkEntry: Identifiable, Equatable {
    let path: [String]
    let isDirectory: Bool
    var id: [String] { path }
    var name: String { path.last ?? "" }
    var isVideo: Bool {
        ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "flv", "wmv", "vob", "ogv", "3gp"].contains((name as NSString).pathExtension.lowercased())
    }
}

enum NetworkSourceError: LocalizedError {
    case invalidAddress, missingServer, missingCredentials, keychain, storage, changedServer, browse
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入有效的 SMB 地址，例如 smb://nas.local/Movies。账户和密码请填在单独的输入框。"
        case .missingServer: "此影片的服务器已移除。请在局域网服务器中重新添加来源并打开影片。"
        case .missingCredentials: "找不到此服务器的登录信息，请编辑服务器并重新保存账户与密码。"
        case .keychain: "无法访问系统钥匙串，请解锁设备后重试。登录信息未保存到普通文件。"
        case .storage: "无法保存服务器配置，请检查设备可用空间后重试。"
        case .changedServer: "服务器地址已更改，请返回片库重新打开影片。"
        case .browse: "无法读取共享目录。请确认设备在同一局域网、已允许本地网络访问，并检查共享名称、账户和权限。"
        }
    }
}
