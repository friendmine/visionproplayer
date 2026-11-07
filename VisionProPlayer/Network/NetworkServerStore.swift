import Foundation
import Observation
import Security

struct NetworkCredentialStore {
    private let service = "com.jeff.visionproplayer.network-servers"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    func load(_ id: UUID) throws -> NetworkCredentials? {
        var request = query(id)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(NetworkCredentials.self, from: data) else { throw NetworkSourceError.keychain }
        return value
    }
    func save(_ value: NetworkCredentials?, for id: UUID) throws {
        let request = query(id)
        guard let value else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NetworkSourceError.keychain }
            return
        }
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw NetworkSourceError.keychain }
        } else if status != errSecSuccess { throw NetworkSourceError.keychain }
    }
}

@MainActor @Observable
final class NetworkServerStore {
    private(set) var servers: [NetworkServer] = []
    private(set) var error: String?
    private let file: URL
    private let credentials = NetworkCredentialStore()
    private var canSave = true

    init(root: URL = URL.applicationSupportDirectory.appending(path: "NetworkSources")) {
        file = root.appending(path: "servers.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let loaded = try JSONDecoder().decode([NetworkServer].self, from: Data(contentsOf: file))
                guard Set(loaded.map(\.id)).count == loaded.count else { throw NetworkSourceError.storage }
                servers = try loaded.map { server in
                    var normalized = server
                    normalized.address = try NetworkServer.validatedRoot(server.address).absoluteString
                    return normalized
                }
            }
        } catch { canSave = false; self.error = "服务器配置无法读取，原记录已保留，暂不覆盖保存。" }
    }
    func server(_ id: UUID) -> NetworkServer? { servers.first { $0.id == id } }
    func login(for server: NetworkServer) throws -> NetworkCredentials {
        guard server.requiresLogin else { return .guest }
        guard let value = try credentials.load(server.id), value.valid else { throw NetworkSourceError.missingCredentials }
        return value
    }
    func save(_ server: NetworkServer, login: NetworkCredentials?) throws {
        guard canSave else { throw NetworkSourceError.storage }
        var normalized = server
        normalized.address = try NetworkServer.validatedRoot(server.address).absoluteString
        normalized.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.name.isEmpty { normalized.name = normalized.hostLabel }
        if normalized.requiresLogin, login?.valid != true { throw NetworkSourceError.missingCredentials }
        let previous = try credentials.load(server.id)
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = normalized }
        else { updated.append(normalized) }
        let data = try JSONEncoder().encode(updated)
        try credentials.save(normalized.requiresLogin ? login : nil, for: server.id)
        do { try data.write(to: file, options: .atomic); servers = updated }
        catch { try? credentials.save(previous, for: server.id); throw NetworkSourceError.storage }
    }
    func remove(_ server: NetworkServer) throws {
        guard canSave else { throw NetworkSourceError.storage }
        let previous = try credentials.load(server.id)
        let updated = servers.filter { $0.id != server.id }
        try credentials.save(nil, for: server.id)
        do { try JSONEncoder().encode(updated).write(to: file, options: .atomic); servers = updated }
        catch { try? credentials.save(previous, for: server.id); throw NetworkSourceError.storage }
    }
    func source(serverID: UUID, path: [String]) throws -> (url: URL, credentials: NetworkCredentials) {
        guard let server = server(serverID) else { throw NetworkSourceError.missingServer }
        return (try server.url(for: path), try login(for: server))
    }
}
