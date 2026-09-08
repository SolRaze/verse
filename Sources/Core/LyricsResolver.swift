import AVFoundation
import Foundation

/// The resolution chain from SPEC §3: sidecar .lrc → embedded tag → LRCLIB → nothing.
/// Results cache to disk so the car isn't waiting on network.
enum LyricsResolver {
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `cacheKey` must be stable per track (library item UUID).
    static func resolve(mediaURL: URL?, title: String, artist: String,
                        duration: TimeInterval?, cacheKey: String) async -> Lyrics? {
        let cacheFile = cacheDir.appendingPathComponent(cacheKey + ".lrc")
        if let cached = try? String(contentsOf: cacheFile, encoding: .utf8) {
            // Empty file = cached miss: the whole chain came up dry once, don't re-hit LRCLIB
            // on every play (issue #4). ponytail: permanent; delete the .lrc to retry a track.
            return cached.isEmpty ? nil : LRCParser.parse(cached)
        }

        var found = sidecar(for: mediaURL)
        if found == nil { found = await embedded(in: mediaURL) }
        if let raw = found {
            try? raw.write(to: cacheFile, atomically: true, encoding: .utf8)
            return LRCParser.parse(raw)
        }

        // LRCLIB (lrclib.net — tranxuanthang/lrclib public instance).
        let client = LRCLibClient()
        let query = LRCLibClient.Query(track: title, artist: artist, duration: duration)
        if let lyrics = try? await client.fetch(query), let raw = rawText(of: lyrics) {
            try? raw.write(to: cacheFile, atomically: true, encoding: .utf8)
            return lyrics
        }
        try? "".write(to: cacheFile, atomically: true, encoding: .utf8)  // negative cache
        return nil
    }

    /// Raw cached text for a track — "" means a cached miss. For the sidecar export.
    static func cachedRaw(for cacheKey: String) -> String? {
        try? String(contentsOf: cacheDir.appendingPathComponent(cacheKey + ".lrc"),
                    encoding: .utf8)
    }

    /// Whether resolved lyrics are cached, as a stat instead of a read. A zero-byte file is the
    /// negative cache, so size alone answers it — `cachedRaw` reads the whole `.lrc` to learn the
    /// same thing, and the fetch review asks this once per track from a view body.
    static func hasLyrics(for cacheKey: String) -> Bool {
        let f = cacheDir.appendingPathComponent(cacheKey + ".lrc")
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return (size ?? 0) > 0
    }

    /// What kind of lyrics a track ended up with, for the Info page (#11). Reads the cache only —
    /// no network, no file open — so a view can ask on every render.
    enum CachedKind: String {
        case synced = "Synced", plain = "Plain", none = "None", unfetched = "Not fetched"
    }

    static func cachedKind(for cacheKey: String) -> CachedKind {
        guard let raw = cachedRaw(for: cacheKey) else { return .unfetched }
        if raw.isEmpty { return .none }     // empty file is the resolver's negative cache
        return LRCParser.parse(raw).isSynced ? .synced : .plain
    }

    /// Drop only a cached MISS (empty file), so a forced re-fetch actually retries LRCLIB.
    /// Found lyrics stay cached.
    static func invalidateNegative(cacheKey: String) {
        let f = cacheDir.appendingPathComponent(cacheKey + ".lrc")
        if (try? String(contentsOf: f, encoding: .utf8))?.isEmpty == true {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// User dropped an .lrc by hand — attach it to a track and cache it.
    static func attach(lrcText: String, cacheKey: String) {
        try? lrcText.write(to: cacheDir.appendingPathComponent(cacheKey + ".lrc"),
                           atomically: true, encoding: .utf8)
    }

    private static func sidecar(for mediaURL: URL?) -> String? {
        guard let mediaURL else { return nil }
        let url = mediaURL.deletingPathExtension().appendingPathExtension("lrc")
        // Security scope covers the picked file, not always its siblings — failure is normal.
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// ID3 USLT / iTunes lyrics via AVAsset. VLC-only containers (ogg/mkv/...) throw — fine.
    /// ponytail: no SYLT support; AVFoundation doesn't expose it. LRCLIB covers synced.
    private static func embedded(in mediaURL: URL?) async -> String? {
        guard let mediaURL else { return nil }
        let asset = AVURLAsset(url: mediaURL)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let lyricIDs: [AVMetadataIdentifier] = [.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics]
        for item in metadata where item.identifier.map(lyricIDs.contains) == true {
            if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
        }
        return nil
    }

    /// Serialize lyrics back to LRC text for the cache.
    private static func rawText(of lyrics: Lyrics) -> String? {
        if lyrics.isSynced {
            return lyrics.lines.map { line in
                let m = Int(line.time) / 60, s = line.time.truncatingRemainder(dividingBy: 60)
                return String(format: "[%02d:%05.2f]%@", m, s, line.text)
            }.joined(separator: "\n")
        }
        return lyrics.plain
    }
}
