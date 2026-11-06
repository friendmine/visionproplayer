import Foundation

@main struct TrackPreferenceTests {
    static func main() throws {
        let native = [PlaybackTrack(id: "0", title: "English", language: "en"), PlaybackTrack(id: "1", title: "Chinese", language: "zh")]
        let vlc = [PlaybackTrack(id: "audio/9", title: "Track 2", language: "zho"), PlaybackTrack(id: "audio/3", title: "Track 1", language: "eng")]
        let saved = SavedPlaybackTrack(native[1], engine: "native")
        print("canonical languages:", vlc.map { $0.languageKey ?? "unknown" })
        assert(saved.resolve(in: native, engine: "native")?.id == "1")
        assert(saved.resolve(in: vlc, engine: "vlc")?.id == "audio/9")
        assert(saved.resolve(in: [vlc[1]], engine: "vlc") == nil)
        let ambiguous = [PlaybackTrack(id: "a", title: "Dub", language: "zh"), PlaybackTrack(id: "b", title: "Commentary", language: "zh")]
        assert(saved.resolve(in: ambiguous, engine: "vlc") == nil)
        let stale = [PlaybackTrack(id: "1", title: "English", language: "en"), PlaybackTrack(id: "5", title: "Chinese", language: "zh")]
        assert(saved.resolve(in: stale, engine: "native")?.id == "5")
        let subtitleOptions = [PlaybackTrack(id: "s0", title: "English", language: "en", isForcedOnly: false),
                               PlaybackTrack(id: "s1", title: "English Forced", language: "en", isForcedOnly: true)]
        let vlcSub = PlaybackTrack(id: "sub/1", title: "Track 1", language: "eng")
        assert(SavedPlaybackTrack(vlcSub, engine: "vlc").resolve(in: subtitleOptions, engine: "native")?.id == "s0")
        assert(SavedPlaybackTrack(subtitleOptions[1], engine: "native").resolve(in: [vlcSub], engine: "vlc") == nil)
        assert(SavedPlaybackTrack(subtitleOptions[1], engine: "native").resolve(in: subtitleOptions, engine: "native")?.id == "s1")
        let off = PlaybackTrackChoices(audio: saved, subtitle: SavedSubtitleChoice(mode: .off))
        let encoded = try JSONEncoder().encode(off)
        let decoded = try JSONDecoder().decode(PlaybackTrackChoices.self, from: encoded)
        assert(decoded == off)
        let absent = try JSONDecoder().decode(PlaybackTrackChoices.self, from: Data("{}".utf8))
        assert(absent.audio == nil && absent.subtitle == nil)
        print("PASS: same-engine identity, cross-engine language normalization, missing/ambiguous tracks, stale IDs and explicit Off persistence")
    }
}
