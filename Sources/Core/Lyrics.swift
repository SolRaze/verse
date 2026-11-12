import Foundation

/// One timed word inside a line. `text` keeps its trailing space, so the words of a line
/// concatenate back to the line.
struct LyricWord: Equatable {
    let time: TimeInterval
    let text: String
}

/// One timed line of an LRC file.
struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
    /// Real word timing from enhanced LRC `<mm:ss.xx>` tags. Empty when the source had none.
    var words: [LyricWord] = []
}

struct Lyrics: Equatable {
    var lines: [LyricLine]      // sorted by time; empty when only plain text exists
    var plain: String?
    var offset: TimeInterval    // LRC `[offset:]`, milliseconds in the file, seconds here

    var isSynced: Bool { !lines.isEmpty }

    /// Index of the line that should be showing at `position`, or nil before the first line.
    func lineIndex(at position: TimeInterval) -> Int? {
        let t = position - offset
        guard let first = lines.first, t >= first.time else { return nil }
        // ponytail: linear scan. Lines are hundreds at most; binary search if a 10k-line file appears.
        var found = 0
        for (i, line) in lines.enumerated() where line.time <= t { found = i }
        return found
    }

    /// Longest stretch a line's words are spread over when the timing is estimated. A line
    /// followed by a long instrumental gap would otherwise crawl through it.
    static let maxLineSpan: TimeInterval = 6

    var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    /// Words of line `i`: real timing when the source carried it, otherwise the line's window
    /// split across its words by length.
    func words(forLine i: Int) -> [LyricWord] {
        guard lines.indices.contains(i) else { return [] }
        let line = lines[i]
        if !line.words.isEmpty { return line.words }
        let parts = line.text.split(separator: " ", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return [] }
        let gap = i + 1 < lines.count ? lines[i + 1].time - line.time : Self.maxLineSpan
        let span = min(max(gap, 0.2), Self.maxLineSpan)
        let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
        var t = line.time
        return parts.enumerated().map { n, part in
            defer { t += span * Double(part.count + 1) / total }
            return LyricWord(time: t, text: n == parts.count - 1 ? String(part) : part + " ")
        }
    }

    /// Index of the word being sung in `words` at `position`, or nil before the first.
    func wordIndex(in words: [LyricWord], at position: TimeInterval) -> Int? {
        let t = position - offset
        return words.lastIndex { $0.time <= t }
    }

    /// LRC text for the cache and the sidecar. Word timing is written back as `<mm:ss.xx>` tags.
    var lrcText: String? {
        guard isSynced else { return plain }
        func stamp(_ t: TimeInterval) -> String {
            String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
        }
        return lines.map { line in
            let body = line.words.isEmpty
                ? line.text
                : line.words.map { "<\(stamp($0.time))>\($0.text)" }.joined()
            return "[\(stamp(line.time))]\(body)"
        }.joined(separator: "\n")
    }

    /// Whether a word-timed result is the same cut of the song as the line-timed one already
    /// held: the first sung lines must start within 2 s of each other. Sources match by name, so
    /// a remix or live version comes back often enough to need this.
    func sameCut(as reference: Lyrics?) -> Bool {
        guard let reference, reference.isSynced else { return true }
        func firstSung(_ l: Lyrics) -> TimeInterval? {
            l.lines.first { !$0.text.isEmpty }.map { $0.time + l.offset }
        }
        guard let a = firstSung(self), let b = firstSung(reference) else { return true }
        return abs(a - b) <= 2
    }
}

// MARK: - LRC parsing

enum LRCParser {
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    /// Enhanced LRC word tag: `<mm:ss.xx>` ahead of each word.
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    /// Parses LRC text. Tolerates multiple timestamps per line, metadata tags, blank lines,
    /// and unsorted input. Returns plain-text lyrics if no timestamps are found at all.
    static func parse(_ raw: String) -> Lyrics {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        for rawLine in raw.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let stamps = tagPattern.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))

            if stamps.isEmpty {
                if let ms = offsetTag(in: rawLine) { offset = ms }
                continue
            }

            // Text is whatever follows the final timestamp on the line.
            let textStart = stamps.last!.range.upperBound
            let (text, lead, tagged) = splitWords(ns.substring(from: textStart))

            for stamp in stamps {
                guard let time = seconds(from: stamp, in: ns) else { continue }
                // Word tags are absolute times, so they fit one stamp only; a repeated line
                // keeps its text and falls back to line timing.
                var words = stamps.count == 1 ? tagged : []
                if !words.isEmpty, !lead.isEmpty {
                    words.insert(LyricWord(time: time, text: lead), at: 0)
                }
                lines.append(LyricLine(time: time, text: text, words: words))
            }
        }

        lines.sort { $0.time < $1.time }

        if lines.isEmpty {
            let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return Lyrics(lines: [], plain: plain.isEmpty ? nil : plain, offset: 0)
        }
        return Lyrics(lines: lines, plain: nil, offset: offset)
    }

    /// Pulls `<mm:ss.xx>` word tags out of a line body. Returns the clean text, any untagged
    /// text before the first tag (sung from the line's own stamp), and the timed words; a body
    /// without tags comes back untouched with no words. A trailing tag with no word after it
    /// marks the line's end and carries no word.
    private static func splitWords(_ body: String) -> (String, String, [LyricWord]) {
        let ns = body as NSString
        let tags = wordPattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard let firstTag = tags.first else {
            return (body.trimmingCharacters(in: .whitespaces), "", [])
        }
        let lead = ns.substring(to: firstTag.range.location)
        var words: [LyricWord] = []
        for (i, tag) in tags.enumerated() {
            let end = i + 1 < tags.count ? tags[i + 1].range.location : ns.length
            let word = ns.substring(with: NSRange(location: tag.range.upperBound,
                                                  length: end - tag.range.upperBound))
            guard !word.trimmingCharacters(in: .whitespaces).isEmpty,
                  let time = seconds(from: tag, in: ns) else { continue }
            words.append(LyricWord(time: time, text: word))
        }
        let text = wordPattern.stringByReplacingMatches(
            in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let leadWord = lead.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : lead.drop { $0 == " " }.description
        return (text.trimmingCharacters(in: .whitespaces), leadWord, words)
    }

    private static func seconds(from match: NSTextCheckingResult, in ns: NSString) -> TimeInterval? {
        guard let min = Double(ns.substring(with: match.range(at: 1))),
              let sec = Double(ns.substring(with: match.range(at: 2))) else { return nil }
        var frac: Double = 0
        if match.range(at: 3).location != NSNotFound {
            let digits = ns.substring(with: match.range(at: 3))
            // "5" -> .5, "50" -> .50, "500" -> .500
            frac = (Double(digits) ?? 0) / pow(10, Double(digits.count))
        }
        return min * 60 + sec + frac
    }

    /// `[offset:+500]` / `[offset:-250]` — milliseconds, positive means lyrics appear earlier.
    private static func offsetTag(in line: String) -> TimeInterval? {
        guard let r = line.range(of: #"\[offset:\s*([+-]?\d+)\s*\]"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let digits = line[r].filter { $0.isNumber || $0 == "-" || $0 == "+" }
        guard let ms = Double(digits) else { return nil }
        return -ms / 1000
    }
}

// MARK: - LRCLIB

/// https://lrclib.net/docs — no auth, no key. Asks callers to send a real User-Agent.
struct LRCLibClient {
    var session: URLSession = .shared
    var userAgent = "Verse/1.0 (personal media player)"

    private struct Response: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    /// One search hit, for the manual lyrics finder (#6g). The automatic path silently picks a
    /// single best match; a human choosing needs to see what the alternatives are, and needs the
    /// raw LRC text carried along so picking one can attach it without a second round trip.
    struct Candidate: Identifiable, Sendable, Equatable {
        var id: Int
        var track: String
        var artist: String
        var album: String
        var duration: Double?
        var synced: Bool
        var raw: String

        /// "Kanye West · Graduation · 3:52 · Synced"
        var detail: String {
            var parts = [artist]
            if !album.isEmpty { parts.append(album) }
            if let d = duration, d > 0 {
                parts.append(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
            }
            parts.append(synced ? "Synced" : "Plain")
            return parts.joined(separator: " · ")
        }
    }

    /// Free-text search returning every hit, in LRCLIB's own relevance order. LRCLIB's `q`
    /// already matches artist as well as track, so the artist pivot (#6d) is native here —
    /// typing "Kanye" returns that artist's songs.
    func candidates(query: String) async throws -> [Candidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        let (data, resp) = try await session.data(for: request(c.url!))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([Response].self, from: data).compactMap { r in
            // A hit with neither synced nor plain text is nothing to attach.
            let raw = r.syncedLyrics ?? r.plainLyrics ?? ""
            guard !raw.isEmpty, let id = r.id else { return nil }
            return Candidate(id: id, track: r.trackName ?? "", artist: r.artistName ?? "",
                             album: r.albumName ?? "", duration: r.duration,
                             synced: !(r.syncedLyrics ?? "").isEmpty, raw: raw)
        }
    }

    struct Query {
        var track: String
        var artist: String
        var album: String? = nil
        var duration: TimeInterval? = nil
    }

    func fetch(_ q: Query) async throws -> Lyrics? {
        if let exact = try await get(q) { return exact }
        return try await search(q)
    }

    /// Exact lookup. 404 is a normal "no match", not an error.
    private func get(_ q: Query) async throws -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            URLQueryItem(name: "track_name", value: q.track),
            URLQueryItem(name: "artist_name", value: q.artist),
            q.album.map { URLQueryItem(name: "album_name", value: $0) },
            q.duration.map { URLQueryItem(name: "duration", value: String(Int($0.rounded()))) },
        ].compactMap { $0 }

        let (data, resp) = try await session.data(for: request(c.url!))
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return lyrics(from: try JSONDecoder().decode(Response.self, from: data))
    }

    /// Fuzzy fallback. Picks the candidate whose duration is closest to ours, within 5s.
    private func search(_ q: Query) async throws -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(q.artist) \(q.track)")]

        let (data, resp) = try await session.data(for: request(c.url!))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let hits = try JSONDecoder().decode([Response].self, from: data)

        let best: Response?
        if let want = q.duration {
            best = hits
                .filter { $0.syncedLyrics != nil }
                .min { abs(($0.duration ?? .infinity) - want) < abs(($1.duration ?? .infinity) - want) }
                .flatMap { abs(($0.duration ?? .infinity) - want) <= 5 ? $0 : nil }
        } else {
            best = hits.first { $0.syncedLyrics != nil } ?? hits.first
        }
        return best.flatMap(lyrics(from:))
    }

    private func lyrics(from r: Response) -> Lyrics? {
        if let synced = r.syncedLyrics, !synced.isEmpty { return LRCParser.parse(synced) }
        if let plain = r.plainLyrics, !plain.isEmpty { return Lyrics(lines: [], plain: plain, offset: 0) }
        return nil
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }
}

// MARK: - Word-timed sources

/// Network sources that carry per-word timing, which LRCLIB does not. Each returns enhanced LRC
/// text (`[mm:ss.xx]<mm:ss.xx>word ...`), the one format the cache and `LRCParser` hold.
enum WordLyricsClient {
    /// `miss`: the source answered and has no word timing. `failed`: no usable answer
    /// (offline, timeout, 429, 5xx, unreadable body), worth a retry on a later play.
    enum Outcome: Equatable { case found(String), miss, failed }

    private struct Failed: Error {}

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    static func fetch(track: String, artist: String, duration: TimeInterval?) async -> Outcome {
        let first = await lrcmux(track: track, artist: artist, duration: duration)
        if case .found = first { return first }
        let second = await netease(track: track, artist: artist, duration: duration)
        if case .found = second { return second }
        return first == .failed || second == .failed ? .failed : .miss
    }

    /// https://api.lrcmux.dev/openapi.json — keyless aggregator over Deezer and KuGou word
    /// timing. `strict` makes a line-only match a miss instead of a downgrade.
    static func lrcmux(track: String, artist: String, duration: TimeInterval?) async -> Outcome {
        var c = URLComponents(string: "https://api.lrcmux.dev/get")!
        c.queryItems = [
            URLQueryItem(name: "title", value: track),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "level", value: "word"),
            URLQueryItem(name: "strict", value: "true"),
            URLQueryItem(name: "format", value: "lrc"),
            duration.map { URLQueryItem(name: "duration", value: String(Int($0.rounded()))) },
        ].compactMap { $0 }
        guard let (data, resp) = try? await session.data(from: c.url!),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 { return .miss }
        guard http.statusCode == 200 else { return .failed }
        guard http.value(forHTTPHeaderField: "x-sync-level") == "word",
              let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return .miss }
        return .found(raw)
    }

    /// NetEase search, then the `yrc` field of the lyric endpoint. Unofficial and keyless; it
    /// answers only to a browser User-Agent.
    static func netease(track: String, artist: String, duration: TimeInterval?) async -> Outcome {
        struct Search: Decodable {
            struct Result: Decodable { let songs: [Song]? }
            struct Song: Decodable { let id: Int; let duration: Double? }   // milliseconds
            let result: Result?
        }
        struct Lyric: Decodable {
            struct Body: Decodable { let lyric: String? }
            let yrc: Body?
        }
        var s = URLComponents(string: "https://music.163.com/api/search/get")!
        s.queryItems = [URLQueryItem(name: "s", value: "\(artist) \(track)"),
                        URLQueryItem(name: "type", value: "1"),
                        URLQueryItem(name: "limit", value: "5")]
        guard let search = try? await get(s.url!, as: Search.self) else { return .failed }
        guard let songs = search.result?.songs, !songs.isEmpty else { return .miss }
        let pick: Search.Song?
        if let want = duration {
            pick = songs.first { abs(($0.duration ?? 0) / 1000 - want) <= 3 }
        } else {
            pick = songs.first
        }
        guard let id = pick?.id else { return .miss }
        var l = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
        l.queryItems = [("id", String(id)), ("lv", "1"), ("yv", "1"), ("tv", "0"), ("rv", "0"),
                        ("kv", "0")].map { name, value in URLQueryItem(name: name, value: value) }
        guard let lyric = try? await get(l.url!, as: Lyric.self) else { return .failed }
        return lyric.yrc?.lyric.flatMap(enhancedLRC(fromYRC:)).map(Outcome.found) ?? .miss
    }

    private static func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        var r = URLRequest(url: url)
        r.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failed() }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static let yrcLine = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let yrcWord = try! NSRegularExpression(
        pattern: #"\((\d+),\d+,\d+\)(.*?)(?=\(\d+,\d+,\d+\)|$)"#)

    /// NetEase `yrc`: `[startMs,durMs](startMs,durMs,0)word (startMs,durMs,0)word`. Credit lines
    /// are JSON objects (`{"t":0,"c":[...]}`) and are dropped. Nil when no line parses.
    static func enhancedLRC(fromYRC yrc: String) -> String? {
        func stamp(_ ms: Double) -> String {
            String(format: "%02d:%05.2f", Int(ms / 1000) / 60,
                   (ms / 1000).truncatingRemainder(dividingBy: 60))
        }
        var out: [String] = []
        for raw in yrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = yrcLine.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  let start = Double(ns.substring(with: m.range(at: 1))) else { continue }
            let body = ns.substring(with: m.range(at: 3)) as NSString
            let words = yrcWord.matches(in: body as String,
                                        range: NSRange(location: 0, length: body.length))
            let text = words.compactMap { w -> String? in
                guard let ms = Double(body.substring(with: w.range(at: 1))) else { return nil }
                return "<\(stamp(ms))>\(body.substring(with: w.range(at: 2)))"
            }.joined()
            if !text.isEmpty { out.append("[\(stamp(start))]\(text)") }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
