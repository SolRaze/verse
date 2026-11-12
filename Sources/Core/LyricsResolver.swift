import AVFoundation
import Foundation

/// The resolution chain from SPEC §3: sidecar .lrc → embedded tag → LRCLIB → nothing.
/// Results cache to disk so the car isn't waiting on network.
enum LyricsResolver {
    /// Recreated on every lookup only when missing: Clear Caches deletes the folder under a
    /// running app, and a `static let` would then point at nothing.
    private static var cacheDir: URL {
        if !FileManager.default.fileExists(atPath: cacheRoot.path) {
            try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        }
        return cacheRoot
    }
    private static let cacheRoot = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lyrics", isDirectory: true)

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
        if let lyrics = try? await client.fetch(query), let raw = lyrics.lrcText {
            try? raw.write(to: cacheFile, atomically: true, encoding: .utf8)
            return lyrics
        }
        try? "".write(to: cacheFile, atomically: true, encoding: .utf8)  // negative cache
        return nil
    }

    /// Word timing for a track whose cached lyrics have none, from `WordLyricsClient`. Runs after
    /// `resolve`, so the line-timed lyrics are already on screen. One answer per track: a miss
    /// or a mismatched cut leaves a `.noword` marker beside the cache file, and Clear Caches is
    /// the retry. A failed fetch leaves no marker, so the next play asks again.
    /// Returns the upgraded lyrics, or nil when nothing changed.
    static func upgradeWords(title: String, artist: String, duration: TimeInterval?,
                             cacheKey: String) async -> Lyrics? {
        guard UserDefaults.standard.bool(forKey: Pref.wordLyrics) else { return nil }
        let marker = cacheDir.appendingPathComponent(cacheKey + ".noword")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let held = cachedRaw(for: cacheKey).flatMap { $0.isEmpty ? nil : LRCParser.parse($0) }
        if held?.hasWordTiming == true { return nil }

        switch await WordLyricsClient.fetch(track: title, artist: artist, duration: duration) {
        case .failed:
            return nil
        case .found(let raw):
            let found = LRCParser.parse(raw)
            if found.hasWordTiming, found.sameCut(as: held) {
                try? raw.write(to: cacheDir.appendingPathComponent(cacheKey + ".lrc"),
                               atomically: true, encoding: .utf8)
                return found
            }
        case .miss:
            break
        }
        markNoWords(cacheKey: cacheKey)
        return nil
    }

    /// Stops `upgradeWords` touching this track again: a miss, or lyrics the user chose.
    static func markNoWords(cacheKey: String) {
        try? Data().write(to: cacheDir.appendingPathComponent(cacheKey + ".noword"))
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

    /// Caches lyrics for a track: an imported sidecar, or a hand pick via `LibraryStore.attachLyrics`.
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
}
