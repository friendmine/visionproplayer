import Foundation

enum FilmSourceFilter: String, CaseIterable {
    case all = "全部来源", files = "文件", photos = "相册", offline = "相册副本", smb = "局域网", web = "视频链接"
}

enum FilmWatchFilter: String, CaseIterable {
    case all = "全部进度", unwatched = "未看", watching = "在看", finished = "已看完"
}

enum FilmOrder: String, CaseIterable {
    case recent = "最近活动", added = "最近添加", title = "片名"
}

extension LibraryFilm {
    var sourceFilter: FilmSourceFilter {
        if networkServerID != nil { return .smb }
        if photoAssetIdentifier != nil { return .photos }
        if photoFile != nil { return .offline }
        return isNetwork ? .web : .files
    }
    var watchFilter: FilmWatchFilter {
        if completed { return .finished }
        return position > 0 ? .watching : .unwatched
    }
}

struct FilmBrowsing {
    var source: FilmSourceFilter = .all
    var watch: FilmWatchFilter = .all
    var order: FilmOrder = .recent

    var filtered: Bool { source != .all || watch != .all }

    func results(in films: [LibraryFilm], search: String, favorites: Bool) -> [LibraryFilm] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return films.filter { film in
            (!favorites || film.favorite)
            && (source == .all || film.sourceFilter == source)
            && (watch == .all || film.watchFilter == watch)
            && (query.isEmpty || film.title.localizedStandardContains(query))
        }.sorted { lhs, rhs in
            switch order {
            case .recent:
                let a = lhs.lastOpened ?? lhs.addedAt
                let b = rhs.lastOpened ?? rhs.addedAt
                if a != b { return a > b }
            case .added:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            case .title: break
            }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
        }
    }
}
