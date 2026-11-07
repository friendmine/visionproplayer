import Foundation
import Observation

@MainActor @Observable
final class NetworkDirectory {
    private(set) var path: [String] = []
    private(set) var entries: [NetworkEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var browser: VPPNetworkBrowser?
    @ObservationIgnored private var token = UUID()

    func load(server: NetworkServer, path: [String], store: NetworkServerStore) {
        cancel()
        self.path = path; entries = []; error = nil
        do {
            let url = try server.url(for: path, directory: true)
            let login = try store.login(for: server)
            let browser = VPPNetworkBrowser(); self.browser = browser
            let token = self.token; loading = true
            browser.list(url: url, credentials: login.dictionary) { [weak self] rows, error in
                guard let self, self.token == token else { return }
                self.loading = false; self.browser = nil
                guard let rows, error == nil else {
                    self.error = error?.localizedDescription ?? NetworkSourceError.browse.localizedDescription
                    return
                }
                var seen = Set<[String]>()
                self.entries = rows.compactMap { row in
                    guard let address = row["url"] as? String, let url = URL(string: address),
                          let child = server.childPath(url, parent: path), seen.insert(child).inserted else { return nil }
                    let entry = NetworkEntry(path: child, isDirectory: row["directory"] as? Bool ?? false)
                    return entry.isDirectory || entry.isVideo ? entry : nil
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancel() {
        token = UUID(); browser?.cancel(); browser = nil; loading = false
    }
    func cancelLoading() { cancel(); error = "已取消连接，可点刷新重试。" }
}
