import Foundation
import UIKit

/// Online metadata lookup: MusicBrainz for title/artist/album, Cover Art Archive for the cover.
/// Free, no API key. Opt-in (Pref.onlineMetadata) — only runs when the user hits Fetch Metadata
/// with the toggle on. MusicBrainz rejects requests without a User-Agent, so every call sets one.
struct MetadataScraper {
    struct Result {
        var title: String
        var artist: String
        var album: String?
        var coverImage: UIImage?
    }

    /// The subset of a MusicBrainz `recording` search we use. Value-typed and Sendable so the
    /// pure parse below is trivially testable offline.
    struct Parsed: Sendable, Equatable {
        var title: String
        var artist: String
        var album: String?
        var releaseMBID: String?
    }

    /// One release candidate from a MusicBrainz release search — what the finder picker shows.
    struct AlbumCandidate: Sendable, Equatable, Identifiable {
        var releaseMBID: String
        var album: String
        var artist: String
        var year: String?
        var trackCount: Int
        var country: String?
        var id: String { releaseMBID }

        /// "2001 · US · 14 tracks" — the detail line under a candidate.
        var detail: String {
            [year, country, "\(trackCount) tracks"].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// A track in a release's medium, disc-aware. Position is 1-based within its disc.
    struct TrackInfo: Sendable, Equatable {
        var title: String
        var track: Int
        var disc: Int
    }

    private static let userAgent = "Verse/0.1 ( github.com/SolRaze/Verse )"

    /// Artist portrait via Deezer's keyless search API (MusicBrainz carries no images).
    /// ponytail: first hit wins; wrong-artist collisions are the user's cue to rename tags.
    static func artistImage(named name: String) async -> UIImage? {
        var comps = URLComponents(string: "https://api.deezer.com/search/artist")!
        comps.queryItems = [.init(name: "q", value: name), .init(name: "limit", value: "1")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["data"] as? [[String: Any]])?.first,
              let pic = (first["picture_xl"] as? String) ?? (first["picture_big"] as? String),
              let picURL = URL(string: pic),
              let (img, _) = try? await URLSession.shared.data(from: picURL)
        else { return nil }
        return UIImage(data: img)
    }

    /// Pure: MusicBrainz recording-search JSON -> top hit. Nil when there are no recordings.
    /// ponytail: JSONSerialization dictionary-walk, not a Codable model — one shape, one caller.
    static func parse(_ data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rec = (root["recordings"] as? [[String: Any]])?.first else { return nil }
        let title = rec["title"] as? String ?? ""
        let artist = (rec["artist-credit"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }.joined() ?? ""
        let release = (rec["releases"] as? [[String: Any]])?.first
        return Parsed(title: title, artist: artist,
                      album: release?["title"] as? String,
                      releaseMBID: release?["id"] as? String)
    }

    /// Lucene query for the recording search. Pure + testable. THE 2026-07-21 bug: an empty
    /// artist used to emit `artist:""`, which matches nothing — every filename-parsed track
    /// (artist unknown) failed, i.e. "fetch never worked". Empty fields are omitted now, and
    /// embedded quotes are stripped so they can't break the query syntax.
    static func buildQuery(title: String, artist: String, filename: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: " ") }
        var parts: [String] = []
        if !title.isEmpty { parts.append("recording:\"\(esc(title))\"") }
        if !artist.isEmpty { parts.append("artist:\"\(esc(artist))\"") }
        if parts.isEmpty { parts.append("recording:\"\(esc(filename))\"") }
        return parts.joined(separator: " AND ")
    }

    /// Search MusicBrainz, then fetch the release's front cover. Falls back to the filename when
    /// tags are empty. Returns nil on any network/parse failure — the caller keeps embedded tags.
    static func lookup(title: String, artist: String, filename: String) async -> Result? {
        let query = buildQuery(title: title, artist: artist, filename: filename)

        // Politeness spacing between tracks too — the caller loops the whole library.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        comps.queryItems = [.init(name: "query", value: query),
                            .init(name: "fmt", value: "json"),
                            .init(name: "limit", value: "1")]
        guard let url = comps.url else { return nil }

        guard let data = await get(url), let parsed = parse(data) else { return nil }

        // ~1s politeness spacing before the second host (MusicBrainz asks callers not to hammer it).
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var cover: UIImage?
        if let mbid = parsed.releaseMBID { cover = await coverArt(mbid: mbid) }
        return Result(title: parsed.title, artist: parsed.artist,
                      album: parsed.album, coverImage: cover)
    }

    // MARK: - Album-level (release search + tracklist)

    /// Pure: a MusicBrainz release-search response -> candidates. Testable offline.
    static func parseCandidates(_ data: Data) -> [AlbumCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = root["releases"] as? [[String: Any]] else { return [] }
        return releases.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
            let artist = (r["artist-credit"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }.joined() ?? ""
            let year = (r["date"] as? String).map { String($0.prefix(4)) }
            let count = (r["track-count"] as? Int)
                ?? (r["media"] as? [[String: Any]])?.reduce(0) { $0 + (($1["track-count"] as? Int) ?? 0) }
                ?? 0
            return AlbumCandidate(releaseMBID: id, album: title, artist: artist,
                                  year: year, trackCount: count, country: r["country"] as? String)
        }
    }

    /// Pure: match a folder's files (by title) to a release's tracklist. Each MB track is
    /// consumed once, so two files with the SAME title don't both grab the first match and end
    /// up with the same track number. Title match (exact, then substring) first; when the counts
    /// line up, any still-unmatched file takes the next remaining track in order. `fileTitles`
    /// and `tracks` are expected pre-sorted by the caller (files by title, tracks by disc/track).
    static func matchTracklist(fileTitles: [String], tracks: [TrackInfo]) -> [TrackInfo?] {
        var remaining = tracks
        var result = [TrackInfo?](repeating: nil, count: fileTitles.count)
        for (i, title) in fileTitles.enumerated() {
            let t = title.lowercased()
            let idx = remaining.firstIndex { $0.title.lowercased() == t }
                ?? remaining.firstIndex { $0.title.lowercased().contains(t) || t.contains($0.title.lowercased()) }
            if let idx { result[i] = remaining.remove(at: idx) }
        }
        if fileTitles.count == tracks.count {
            for i in result.indices where result[i] == nil && !remaining.isEmpty {
                result[i] = remaining.removeFirst()
            }
        }
        return result
    }

    /// Pure: a MusicBrainz release lookup (inc=recordings) -> ordered, disc-aware tracklist.
    static func parseTracklist(_ data: Data) -> [TrackInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = root["media"] as? [[String: Any]] else { return [] }
        var out: [TrackInfo] = []
        for (mi, medium) in media.enumerated() {
            let disc = (medium["position"] as? Int) ?? (mi + 1)
            for t in (medium["tracks"] as? [[String: Any]] ?? []) {
                guard let title = t["title"] as? String else { continue }
                out.append(TrackInfo(title: title, track: (t["position"] as? Int) ?? 0, disc: disc))
            }
        }
        return out
    }

    /// Release search for the finder picker (top matches). One field per non-empty term.
    static func albumCandidates(album: String, artist: String, limit: Int = 6) async -> [AlbumCandidate] {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: " ") }
        var parts: [String] = []
        if !album.isEmpty { parts.append("release:\"\(esc(album))\"") }
        if !artist.isEmpty { parts.append("artist:\"\(esc(artist))\"") }
        guard !parts.isEmpty else { return [] }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        comps.queryItems = [.init(name: "query", value: parts.joined(separator: " AND ")),
                            .init(name: "fmt", value: "json"),
                            .init(name: "limit", value: String(limit))]
        guard let url = comps.url, let data = await get(url) else { return [] }
        return parseCandidates(data)
    }

    /// Free-text search for the finder sheets (#6d). The query is matched against the release
    /// title OR the artist name, so typing an artist pivots to that artist's releases instead of
    /// returning nothing — `albumCandidates` above ANDs the two and is title-led, which is right
    /// for a tag-seeded lookup and wrong for a human typing "Kanye".
    static func searchReleases(query: String, limit: Int = 12) async -> [AlbumCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: " ")
        guard !q.isEmpty else { return [] }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        comps.queryItems = [.init(name: "query", value: "release:\"\(q)\" OR artist:\"\(q)\""),
                            .init(name: "fmt", value: "json"),
                            .init(name: "limit", value: String(limit))]
        guard let url = comps.url, let data = await get(url) else { return [] }
        return parseCandidates(data)
    }

    /// Full tracklist + front cover for one release. `wantCover` skips the CAA hop when not needed.
    static func albumDetail(mbid: String, wantCover: Bool = true)
        async -> (tracks: [TrackInfo], cover: UIImage?) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(mbid)")!
        comps.queryItems = [.init(name: "inc", value: "recordings"),
                            .init(name: "fmt", value: "json")]
        var tracks: [TrackInfo] = []
        if let url = comps.url, let data = await get(url) { tracks = parseTracklist(data) }
        var cover: UIImage?
        if wantCover {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            cover = await coverArt(mbid: mbid)
        }
        return (tracks, cover)
    }

    /// Cover Art Archive front image, 500px, falling back to full size on 404. Redirects to
    /// archive.org for the bytes — URLSession follows them.
    static func coverArt(mbid: String) async -> UIImage? {
        for size in ["front-500", "front"] {
            guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/\(size)"),
                  let data = await get(url), let img = UIImage(data: data) else { continue }
            return img
        }
        return nil
    }

    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
