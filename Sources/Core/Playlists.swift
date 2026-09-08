import Foundation

/// Remote playlist sources — YouTube playlists/channels, Spotify playlists, SoundCloud sets —
/// pulled into one place and matched against files already in the library.
///
/// All fetchers are keyless: YouTube via the public innertube endpoint, Spotify via its embed
/// page, SoundCloud via the hydration JSON + a client_id scraped from their web bundle. Every
/// one of these is scraping and will eventually break; each is isolated in one small function
/// so the fix is local. Personal sideloaded build — see README's legal note.
struct RemotePlaylist: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case youtubePlaylist, youtubeChannel, spotify, soundcloud
    }

    struct Entry: Codable, Hashable {
        var title: String
        var artist: String
        var watchURL: URL?      // set for YouTube entries; nil means "find it" (Spotify/SC)
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var sourceURL: URL
    var entries: [Entry]
    var fetchedAt: Date
}

@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [RemotePlaylist] = []

    private var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists.json")
    }

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([RemotePlaylist].self, from: data) {
            playlists = saved
        }
    }

    private func save() {
        try? JSONEncoder().encode(playlists).write(to: file, options: .atomic)
    }

    /// Add (or refresh, if the same source URL exists) a playlist from any supported URL.
    func add(url: URL) async throws {
        let fresh = try await PlaylistFetcher.fetch(url: url)
        if let i = playlists.firstIndex(where: { $0.sourceURL == fresh.sourceURL }) {
            var kept = fresh
            kept.id = playlists[i].id
            playlists[i] = kept
        } else {
            playlists.append(fresh)
        }
        save()
    }

    func refresh(_ playlist: RemotePlaylist) async throws {
        try await add(url: playlist.sourceURL)
    }

    func remove(_ playlist: RemotePlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }
}

// MARK: - Matching remote entries to downloaded files

enum PlaylistMatcher {
    /// Lowercased alphanumerics only — survives punctuation, casing, and "(Official Video)" noise
    /// well enough for a personal library.
    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The library item this entry is "already downloaded" as, if any.
    static func match(_ entry: RemotePlaylist.Entry, in items: [LibraryItem]) -> LibraryItem? {
        let want = normalized(entry.title)
        guard want.count >= 4 else { return nil }
        return items.first { item in
            guard case .file = item.source else { return false }
            let have = normalized(item.artist.isEmpty ? item.title : item.artist + item.title)
            let haveTitle = normalized(item.title)
            return want.contains(haveTitle) && haveTitle.count >= 4
                || have.contains(want) || want.contains(have)
        }
    }
}

// MARK: - Fetchers

enum PlaylistFetcher {
    enum FetchError: LocalizedError {
        case unsupportedURL, parseFailed(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedURL:
                return "Not a YouTube playlist/channel, Spotify playlist, or SoundCloud set link."
            case .parseFailed(let source):
                return "\(source) gave a page this app no longer understands — the scraper needs updating."
            }
        }
    }

    // Desktop UA: SoundCloud and Spotify serve server-rendered HTML to a desktop browser and a
    // JS-only app shell to mobile. YouTube's keyless innertube doesn't care either way.
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func fetch(url: URL) async throws -> RemotePlaylist {
        let host = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        if host.contains("youtube.com") || host.contains("youtu.be") {
            if let listID = query.first(where: { $0.name == "list" })?.value {
                return try await youtubePlaylist(id: listID, sourceURL: url)
            }
            return try await youtubeChannel(url: url)
        }
        if host.contains("spotify.com"), url.path.contains("/playlist/") {
            return try await spotifyPlaylist(id: url.lastPathComponent, sourceURL: url)
        }
        if host.contains("soundcloud.com") {
            return try await soundcloudSet(url: url)
        }
        throw FetchError.unsupportedURL
    }

    /// One innertube search, used to play a Spotify/SoundCloud entry that isn't downloaded:
    /// best-effort "first result" — exactly what typing it into YouTube would do.
    static func youtubeSearch(_ terms: String) async throws -> URL {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20240101.00.00"]],
            "query": terms,
        ]
        let data = try await innertube("search", body: body)
        let hits = scan(try JSONSerialization.jsonObject(with: data), for: "videoRenderer")
        guard let id = hits.first?["videoId"] as? String,
              let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else {
            throw FetchError.parseFailed("YouTube search")
        }
        return url
    }

    // MARK: YouTube

    private static func youtubePlaylist(id: String, sourceURL: URL) async throws -> RemotePlaylist {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20240101.00.00"]],
            "browseId": "VL" + id,
        ]
        let data = try await innertube("browse", body: body)
        let json = try JSONSerialization.jsonObject(with: data)

        // ponytail: first page only (~100 items), no continuation tokens. Paginate when a
        // playlist that long actually matters.
        // YouTube migrated playlist rows from playlistVideoRenderer to lockupViewModel; support
        // both so an old cached response and a fresh one both parse.
        let entries: [RemotePlaylist.Entry] =
            scan(json, for: "playlistVideoRenderer").compactMap { v in
                guard let videoID = v["videoId"] as? String,
                      let title = firstRunText(v["title"]),
                      let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
                return .init(title: title, artist: firstRunText(v["shortBylineText"]) ?? "", watchURL: url)
            }
            + scan(json, for: "lockupViewModel").compactMap { lockup -> RemotePlaylist.Entry? in
                guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
                      let videoID = lockup["contentId"] as? String,
                      let meta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any],
                      let title = (meta["title"] as? [String: Any])?["content"] as? String,
                      let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
                // Channel name lives in the avatar's a11y label: "Go to channel NAME".
                let artist = (scan(meta, for: "decoratedAvatarViewModel").first?["a11yLabel"] as? String)
                    .map { $0.replacingOccurrences(of: "Go to channel ", with: "") } ?? ""
                return .init(title: title, artist: artist, watchURL: url)
            }
        guard !entries.isEmpty else { throw FetchError.parseFailed("YouTube playlist") }

        let name = scan(json, for: "microformatDataRenderer").first?["title"] as? String
        return RemotePlaylist(title: name ?? "YouTube playlist", kind: .youtubePlaylist,
                              sourceURL: sourceURL, entries: entries, fetchedAt: .now)
    }

    /// "Subscriptions" without Google OAuth: add channels you care about; each shows its recent
    /// uploads via the public RSS feed. Stable API, no key, capped at 15 items by YouTube.
    private static func youtubeChannel(url: URL) async throws -> RemotePlaylist {
        let page = try await htmlString(url)
        guard let channelID = capture(#""channelId":"(UC[0-9A-Za-z_-]{22})""#, in: page) else {
            throw FetchError.parseFailed("YouTube channel")
        }
        let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")!
        let xml = try await htmlString(feedURL)

        let channelName = capture(#"<title>([^<]+)</title>"#, in: xml) ?? "Channel"
        let entries: [RemotePlaylist.Entry] = xml.components(separatedBy: "<entry>").dropFirst().compactMap { block in
            guard let id = capture(#"<yt:videoId>([^<]+)</yt:videoId>"#, in: block),
                  let title = capture(#"<title>([^<]+)</title>"#, in: block),
                  let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return nil }
            return .init(title: title, artist: channelName, watchURL: url)
        }
        guard !entries.isEmpty else { throw FetchError.parseFailed("YouTube channel feed") }
        return RemotePlaylist(title: channelName, kind: .youtubeChannel,
                              sourceURL: url, entries: entries, fetchedAt: .now)
    }

    private static func innertube(_ endpoint: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: Spotify

    /// Public playlists via the embed page's __NEXT_DATA__ JSON — no OAuth, no developer app.
    private static func spotifyPlaylist(id: String, sourceURL: URL) async throws -> RemotePlaylist {
        let embed = URL(string: "https://open.spotify.com/embed/playlist/\(id)")!
        let page = try await htmlString(embed)
        guard let raw = capture(#"<script id="__NEXT_DATA__" type="application/json">(.+?)</script>"#, in: page),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
            throw FetchError.parseFailed("Spotify")
        }

        let entities = scan(json, for: "trackList")
        guard let entity = entities.first,
              let trackList = entity["trackList"] as? [[String: Any]], !trackList.isEmpty else {
            throw FetchError.parseFailed("Spotify")
        }

        let entries: [RemotePlaylist.Entry] = trackList.compactMap { t in
            guard let title = t["title"] as? String else { return nil }
            return .init(title: title, artist: t["subtitle"] as? String ?? "", watchURL: nil)
        }
        let name = (entity["title"] as? String) ?? (entity["name"] as? String) ?? "Spotify playlist"
        return RemotePlaylist(title: name, kind: .spotify,
                              sourceURL: sourceURL, entries: entries, fetchedAt: .now)
    }

    // MARK: SoundCloud

    private static func soundcloudSet(url: URL) async throws -> RemotePlaylist {
        // resolve?url= turns any soundcloud.com link into its api-v2 object. Far more stable than
        // scraping the page, which now serves a JS-only shell to most clients.
        let clientID = try await soundcloudClientID()
        var c = URLComponents(string: "https://api-v2.soundcloud.com/resolve")!
        c.queryItems = [.init(name: "url", value: url.absoluteString),
                        .init(name: "client_id", value: clientID)]
        let (data, resp) = try await URLSession.shared.data(for: request(c.url!))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let playlist = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            throw FetchError.parseFailed("SoundCloud")
        }

        // resolve inlines the first tracks fully; the rest are id-only stubs fetched in a batch.
        var full = tracks.filter { $0["title"] != nil }
        let stubIDs = tracks.compactMap { $0["title"] == nil ? $0["id"] as? Int : nil }
        if !stubIDs.isEmpty {
            full += (try? await soundcloudTracks(ids: stubIDs, clientID: clientID)) ?? []
        }

        let entries: [RemotePlaylist.Entry] = full.compactMap { t in
            guard let title = t["title"] as? String else { return nil }
            let user = (t["user"] as? [String: Any])?["username"] as? String ?? ""
            return .init(title: title, artist: user, watchURL: nil)
        }
        guard !entries.isEmpty else { throw FetchError.parseFailed("SoundCloud") }
        return RemotePlaylist(title: playlist["title"] as? String ?? "SoundCloud set",
                              kind: .soundcloud, sourceURL: url, entries: entries, fetchedAt: .now)
    }

    /// The client_id lives in one of SoundCloud's JS bundles and rotates occasionally.
    private static func soundcloudClientID() async throws -> String {
        let home = try await htmlString(URL(string: "https://soundcloud.com")!)
        let scripts = captures(#"src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#, in: home)
        for src in scripts.reversed() {   // client_id is usually in one of the last bundles
            guard let url = URL(string: src), let js = try? await htmlString(url) else { continue }
            if let id = capture(#"client_id:"([0-9A-Za-z]{32})""#, in: js) { return id }
        }
        throw FetchError.parseFailed("SoundCloud client_id")
    }

    private static func soundcloudTracks(ids: [Int], clientID: String) async throws -> [[String: Any]] {
        // ponytail: one batch of 50; sets longer than that lose the tail until batching matters.
        let idList = ids.prefix(50).map(String.init).joined(separator: ",")
        let url = URL(string: "https://api-v2.soundcloud.com/tracks?ids=\(idList)&client_id=\(clientID)")!
        let (data, _) = try await URLSession.shared.data(for: request(url))
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: helpers

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        return r
    }

    private static func htmlString(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: request(url))
        return String(decoding: data, as: UTF8.self)
    }

    /// Recursively collect every dictionary reachable under `key` — survives the deeply nested,
    /// frequently reshuffled JSON these sites emit better than hardcoded key paths do.
    private static func scan(_ any: Any, for key: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = any as? [String: Any] {
            if let hit = dict[key] as? [String: Any] { found.append(hit) }
            if dict[key] is [[String: Any]] { found.append(dict) }   // key holds an array: keep parent
            for v in dict.values { found += scan(v, for: key) }
        } else if let arr = any as? [Any] {
            for v in arr { found += scan(v, for: key) }
        }
        return found
    }

    /// YouTube text objects: {"runs":[{"text":...}]} or {"simpleText":...}.
    private static func firstRunText(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        return ((dict["runs"] as? [[String: Any]])?.first?["text"]) as? String
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil }
    }

    private static func slice(_ text: String, from: String, to: String) -> String? {
        guard let a = text.range(of: from), let b = text.range(of: to, range: a.upperBound..<text.endIndex)
        else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }
}
