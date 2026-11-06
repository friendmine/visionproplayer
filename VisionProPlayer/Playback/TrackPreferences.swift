import Foundation

struct PlaybackTrack: Identifiable, Equatable {
    let id: String
    let title: String
    var language: String? = nil
    // LibVLC does not expose this flag; nil means unknown, not forced-only.
    var isForcedOnly: Bool? = nil

    var languageKey: String? {
        guard let language, !language.isEmpty else { return nil }
        let tag = Locale.canonicalLanguageIdentifier(from: language).lowercased()
        return ["und", "unknown", ""].contains(tag) ? nil : tag
    }
    var titleKey: String { title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Decoder IDs are only meaningful for their source and engine. Metadata is
/// retained for cross-engine matching; ambiguous matches keep the saved intent.
struct SavedPlaybackTrack: Codable, Equatable {
    let engine: String
    let identifier: String
    let title: String
    let language: String?
    let isForcedOnly: Bool?

    init(_ track: PlaybackTrack, engine: String) {
        self.engine = engine; identifier = track.id
        title = track.titleKey; language = track.languageKey; isForcedOnly = track.isForcedOnly
    }

    func resolve(in tracks: [PlaybackTrack], engine: String) -> PlaybackTrack? {
        if self.engine == engine,
           let same = tracks.first(where: { $0.id == identifier && $0.titleKey == title && $0.languageKey == language }) { return same }
        // Never substitute a known forced-only option for a full/unknown track.
        // A known forced-only choice requires explicit evidence on the target.
        let candidates = tracks.filter { isForcedOnly == true ? $0.isForcedOnly == true : $0.isForcedOnly != true }
        let named = candidates.filter { $0.titleKey == title && $0.languageKey == language }
        if named.count == 1 { return named[0] }
        if let language {
            let localized = candidates.filter { $0.languageKey == language }
            if localized.count == 1 { return localized[0] }
        }
        return nil
    }
}

struct SavedSubtitleChoice: Codable, Equatable {
    enum Mode: String, Codable { case off, external, embedded }
    var mode: Mode
    var track: SavedPlaybackTrack? = nil
}

struct PlaybackTrackChoices: Codable, Equatable {
    var audio: SavedPlaybackTrack?
    var subtitle: SavedSubtitleChoice?
}
