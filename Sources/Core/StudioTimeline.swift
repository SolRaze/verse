import Foundation

/// One stretch of video on the Lyric Studio timeline. Clips sit back to back with no gaps, so a
/// clip's place in time is the sum of the durations before it.
struct StudioClip: Codable, Identifiable, Equatable {
    var id = UUID()
    /// File name inside `StudioProject.folder`.
    var file: String
    /// Where in the source file this clip starts, seconds.
    var sourceStart: Double
    var duration: Double
    /// Full length of the source file, the ceiling for un-trimming.
    var sourceDuration: Double
    /// Dissolve in from the last frame of the clip before it, instead of a hard cut.
    var fadeIn = false
}

/// A Lyric Studio draft. The song is the spine: the timeline is `songDuration` long, the audio
/// and the lyrics are locked to it, and clips only fill that length with picture. No edit to a
/// clip can move a word out of time.
struct StudioProject: Codable, Equatable {
    var songID: UUID
    var songTitle: String
    /// Start of the chosen lyric range inside the song, seconds.
    var songStart: Double
    var songDuration: Double
    /// The song's LRC text at creation, so the draft opens without the lyrics cache.
    var lyricsRaw: String?
    var clips: [StudioClip] = []
    /// Vertical centre of the lyrics, 0 top to 1 bottom.
    var lyricsY = 0.75
    var wordByWord = true
    var fontSize = 64.0

    /// Longest lyric range a project may cover, seconds.
    static let maxRange = 60.0

    static var folder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var draftFile: URL { folder.appendingPathComponent("draft.json") }

    static var hasDraft: Bool { FileManager.default.fileExists(atPath: draftFile.path) }

    static func loadDraft() -> StudioProject? {
        (try? Data(contentsOf: draftFile)).flatMap { try? JSONDecoder().decode(StudioProject.self, from: $0) }
    }

    func saveDraft() {
        try? JSONEncoder().encode(self).write(to: Self.draftFile, options: .atomic)
    }

    /// Drops the draft and every take and imported clip with it.
    static func discardDraft() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Every timeline edit, as a pure function from clips to clips. Each one keeps the invariants:
/// no clip shorter than `minClip`, no clip reaching outside its source file, and the total
/// never longer than `limit`.
enum StudioTimeline {
    static let minClip = 0.3

    static func total(_ clips: [StudioClip]) -> Double { clips.reduce(0) { $0 + $1.duration } }

    /// Timeline time at which clip `index` starts.
    static func start(of index: Int, in clips: [StudioClip]) -> Double {
        clips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    /// The clip playing at `time`. The end of the timeline belongs to the last clip.
    static func index(at time: Double, in clips: [StudioClip]) -> Int? {
        guard !clips.isEmpty else { return nil }
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            t += clip.duration
            if time < t { return i }
        }
        return clips.count - 1
    }

    /// Cuts the clip under `time` in two. Nothing happens within `minClip` of either edge.
    static func split(_ clips: [StudioClip], at time: Double) -> [StudioClip] {
        guard let i = index(at: time, in: clips) else { return clips }
        let into = time - start(of: i, in: clips)
        let clip = clips[i]
        guard into >= minClip, clip.duration - into >= minClip else { return clips }
        var left = clip, right = clip
        left.duration = into
        right.id = UUID()
        right.sourceStart = clip.sourceStart + into
        right.duration = clip.duration - into
        right.fadeIn = false
        var out = clips
        out.replaceSubrange(i ... i, with: [left, right])
        return out
    }

    /// Removes a clip. The ones after it slide left and meet the one before: that is the merge.
    static func remove(_ clips: [StudioClip], id: UUID) -> [StudioClip] {
        clips.filter { $0.id != id }
    }

    /// Moves a clip one place left (`-1`) or right (`+1`).
    static func move(_ clips: [StudioClip], id: UUID, by delta: Int) -> [StudioClip] {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips.indices.contains(i + delta) else { return clips }
        var out = clips
        out.swapAt(i, i + delta)
        return out
    }

    /// Makes the clip under `time` start at `time`, dropping what came before it in that clip.
    static func trimStart(_ clips: [StudioClip], at time: Double) -> [StudioClip] {
        guard let i = index(at: time, in: clips) else { return clips }
        let into = time - start(of: i, in: clips)
        guard into > 0, clips[i].duration - into >= minClip else { return clips }
        var out = clips
        out[i].sourceStart += into
        out[i].duration -= into
        return out
    }

    /// Makes the clip under `time` end at `time`, dropping the rest of that clip.
    static func trimEnd(_ clips: [StudioClip], at time: Double) -> [StudioClip] {
        guard let i = index(at: time, in: clips) else { return clips }
        let into = time - start(of: i, in: clips)
        guard into >= minClip, into < clips[i].duration else { return clips }
        var out = clips
        out[i].duration = into
        return out
    }

    /// Puts `clip` at `time`, cutting the clip already there in two around it, then trims the
    /// tail so the whole timeline still fits in `limit`.
    static func insert(_ clip: StudioClip, into clips: [StudioClip], at time: Double,
                       limit: Double) -> [StudioClip] {
        var out = split(clips, at: time)
        // After the split a clip boundary sits at `time` unless it fell too near an edge; then
        // the new clip goes after the clip it landed in.
        var at = out.count
        var t = 0.0
        for (i, c) in out.enumerated() {
            if time <= t + 0.0001 { at = i; break }
            t += c.duration
        }
        out.insert(clip, at: at)
        return fit(out, to: limit)
    }

    /// Trims from the end until the timeline is no longer than `limit`. Clips left shorter than
    /// `minClip` are dropped.
    static func fit(_ clips: [StudioClip], to limit: Double) -> [StudioClip] {
        var out: [StudioClip] = []
        var room = limit
        for var clip in clips {
            guard room >= minClip else { break }
            clip.duration = min(clip.duration, room)
            out.append(clip)
            room -= clip.duration
        }
        return out
    }
}
