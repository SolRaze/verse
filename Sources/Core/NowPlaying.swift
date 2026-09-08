import ActivityKit
import Foundation
import MediaPlayer
import UIKit

/// The entire CarPlay surface.
///
/// No CarPlay entitlement and no CPTemplateApplicationSceneDelegate are involved. Any app that
/// plays audio and populates MPNowPlayingInfoCenter appears on the car's Now Playing screen for
/// free; the steering-wheel and dashboard controls arrive through MPRemoteCommandCenter.
///
/// The interesting part is `render(...)`: the car draws the artwork large, so we draw the current
/// synced-lyric window into the artwork and republish it whenever the line changes. That puts
/// karaoke lyrics on the car display with no entitlement at all.
@MainActor
final class NowPlaying {
    struct Track {
        var title: String
        var artist: String
        var album: String?
        var duration: TimeInterval
        var artwork: UIImage?
    }

    /// Wire these to the player. Called from the car, the lock screen, and headphone buttons.
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
    }

    /// "CarPlay Lyrics" in Settings: pushes the current line into the artist field, which every
    /// head unit updates reliably. Artwork is always the real cover — never render lyrics into
    /// it.
    var lyricsInTextFieldFallback: Bool {
        UserDefaults.standard.bool(forKey: Pref.carPlayTextFallback)
    }

    private let center = MPNowPlayingInfoCenter.default()
    private var track: Track?
    private var lyrics: Lyrics?

    /// What was last handed to MPNowPlayingInfoCenter, and when. Assigning `nowPlayingInfo` is an
    /// XPC round trip to mediaserverd; VLC ticks ~4x a second, so doing it per tick meant a
    /// continuous stream of them for the life of every track. The contract is elapsed time plus
    /// playback rate — the system extrapolates elapsed between publishes, which is exactly what
    /// makes a smooth scrubber possible without per-frame updates. So publish only when the
    /// extrapolation would be wrong.
    private struct Published {
        var position: TimeInterval
        var at: Date
        var playing: Bool
        var duration: TimeInterval
        var lyricLine: String?
    }
    private var lastPublished: Published?

    /// How far the car's extrapolated position may drift before we correct it.
    private static let driftTolerance: TimeInterval = 1.5

    init(commands: Commands) {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { _ in commands.play(); return .success }
        rc.pauseCommand.addTarget { _ in commands.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            (self?.isPlaying ?? false) ? commands.pause() : commands.play(); return .success
        }
        rc.nextTrackCommand.addTarget { _ in commands.next(); return .success }
        rc.previousTrackCommand.addTarget { _ in commands.previous(); return .success }
        rc.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            commands.seek(e.positionTime)
            return .success
        }
        // A crash or force-quit never runs end(), so last session's lyric activity is still on
        // the Lock Screen AND still occupies ActivityKit's slot — which makes the next song's
        // request fail silently. Clear anything left over the moment we launch.
        Task { await endAllActivities() }
    }

    private var isPlaying: Bool {
        (center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
    }

    func begin(track: Track, lyrics: Lyrics?) {
        self.track = track
        self.lyrics = lyrics
        lastPublished = nil
        publish(position: 0, playing: false, image: track.artwork, lyricLine: nil)
        startActivity()
    }

    /// Late attach after begin() (issue #4): publish artwork once, adopt lyrics and start the
    /// Live Activity that begin() skipped because they hadn't resolved yet.
    func attach(lyrics: Lyrics?, artwork: UIImage?) {
        guard track != nil else { return }
        if let artwork {
            track?.artwork = artwork
            let pos = center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime]
                as? TimeInterval ?? 0
            publish(position: pos, playing: isPlaying, image: artwork, lyricLine: nil)
        }
        if let lyrics {
            self.lyrics = lyrics
            if !activityIsLive { startActivity() }
        }
    }

    func end() {
        track = nil
        lyrics = nil
        lastPublished = nil
        center.nowPlayingInfo = nil
        endActivity()
    }

    /// Forget the publish gate, so the next `update` reaches the info centre whatever it says.
    /// A seek shorter than the drift tolerance is still a seek — the car must be told, or its
    /// scrubber sits where the user dragged it from.
    func invalidatePublishGate() { lastPublished = nil }

    /// Call on every player tick and on every play/pause/seek. Artwork never changes here —
    /// the real cover published by begin()/attach() stays; ticks only refresh timing (and the
    /// lyric line in the artist field when the CarPlay Lyrics toggle is on).
    /// `duration` rides the tick because VLC only knows it after playback starts — begin()
    /// publishes 0, which left the lock screen with no scrubber or length (issue #6).
    func update(position: TimeInterval, duration: TimeInterval = 0, playing: Bool) {
        if duration > 0, duration != track?.duration { track?.duration = duration }
        guard let track else { return }

        guard let lyrics, lyrics.isSynced else {
            publish(position: position, playing: playing, image: track.artwork, lyricLine: nil)
            return
        }

        let index = lyrics.lineIndex(at: position)
        syncActivity(index: index, playing: playing)
        let line = lyricsInTextFieldFallback ? index.map { lyrics.lines[$0].text } : nil
        publish(position: position, playing: playing, image: nil, lyricLine: line)
    }

    /// `image: nil` keeps whatever artwork is already published — reassigning MPMediaItemArtwork
    /// on every tick makes some head units flicker.
    private func publish(position: TimeInterval, playing: Bool, image: UIImage?, lyricLine: String?) {
        guard let track else { return }

        // Skip the round trip when the car can already work out this state for itself. Artwork
        // always publishes: it is only ever passed on a real change (begin/attach).
        if image == nil, let last = lastPublished,
           last.playing == playing, last.duration == track.duration, last.lyricLine == lyricLine {
            let expected = last.playing
                ? last.position + Date().timeIntervalSince(last.at)
                : last.position
            if abs(expected - position) < Self.driftTolerance { return }
        }
        lastPublished = Published(position: position, at: Date(), playing: playing,
                                  duration: track.duration, lyricLine: lyricLine)

        var info = center.nowPlayingInfo ?? [:]

        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyAlbumTitle] = track.album
        info[MPMediaItemPropertyPlaybackDuration] = track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0

        if lyricsInTextFieldFallback, let lyricLine {
            info[MPMediaItemPropertyArtist] = lyricLine
        } else {
            info[MPMediaItemPropertyArtist] = track.artist
        }

        if let image {
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }

        center.nowPlayingInfo = info
    }

    /// MediaPlayer calls the artwork block on ITS queue (e.g. jpegDataWithSize:), not main.
    /// Built inside a @MainActor method the closure inherits main-actor isolation and the Swift 6
    /// runtime dispatch-asserts — SIGTRAP. nonisolated here is load-bearing, not style.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Live Activity (per-line lyrics on the Lock Screen, SPEC §6)

    private var activity: Activity<LyricActivityAttributes>?
    private var activityState: LyricActivityAttributes.ContentState?
    /// Guards the async end→request window so begin() and a late attach() can't both fire a
    /// request and leave two activities on screen.
    private var mutatingActivity = false

    /// App returned to foreground: iOS forbids STARTING a Live Activity from the background, so a
    /// track that auto-advanced while backgrounded has none. Start it now that we're active.
    func resumeActivityIfNeeded() {
        guard !activityIsLive, track != nil, lyrics?.isSynced == true, isPlaying else { return }
        startActivity()
    }

    /// True only while our activity is actually on screen. After the user swipes it away it goes
    /// `.dismissed` (or `.ended`) but our reference lingers — treating that as "still live" is why
    /// the next song never got one, so callers gate on this, not `activity != nil`.
    private var activityIsLive: Bool {
        if let activity, activity.activityState == .active { return true }
        return false
    }

    /// One activity per track, only when synced lyrics exist — a lyric-less track has nothing
    /// to show that the system now-playing surface doesn't already.
    /// ponytail: iOS forbids STARTING a Live Activity from the background, so a track that
    /// auto-advances while the app is backgrounded won't get one until foreground. No API works
    /// around that; the old activity is still ended so at least nothing stale lingers.
    private func startActivity() {
        guard !mutatingActivity else { return }
        guard let track, let lyrics, lyrics.isSynced,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Seed from the CURRENT position, not an empty state — otherwise a mid-song attach()
        // shows the song title for one tick before the first sync corrects it (the flash).
        let pos = center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime]
            as? TimeInterval ?? 0
        let state = contentState(index: lyrics.lineIndex(at: pos), playing: isPlaying)
        let attrs = LyricActivityAttributes(title: track.title, artist: track.artist)
        activityState = state
        mutatingActivity = true
        // End every existing activity FIRST and await it, so the slot is free — requesting while
        // the previous one is still ending is what left new songs with no activity.
        Task {
            await endAllActivities()
            activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
            mutatingActivity = false
        }
    }

    /// Build the three-line window (previous/current/next) for a line index. Shared by the
    /// initial seed and every tick so they can't disagree.
    private func contentState(index: Int?, playing: Bool) -> LyricActivityAttributes.ContentState {
        let lines = lyrics?.lines ?? []
        return LyricActivityAttributes.ContentState(
            previous: index.flatMap { $0 > 0 ? lines[$0 - 1].text : nil } ?? "",
            current: index.map { lines[$0].text } ?? "",
            next: index.map { $0 + 1 < lines.count ? lines[$0 + 1].text : "" }
                ?? lines.first?.text ?? "",
            isPlaying: playing)
    }

    /// Cheap when nothing changed: dedups on ContentState equality, so it only hits ActivityKit
    /// on a line change or a play/pause flip — seconds apart, well inside update budgets.
    private func syncActivity(index: Int?, playing: Bool) {
        guard let activity else { return }
        let state = contentState(index: index, playing: playing)
        guard state != activityState else { return }
        activityState = state
        let sent = Sent(activity)
        Task { await sent.value.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        activityState = nil
        Task { await endAllActivities() }
    }

    /// End the tracked activity AND any orphan of this type — awaitable so callers can free the
    /// ActivityKit slot before requesting a replacement.
    private func endAllActivities() async {
        activity = nil
        for a in Activity<LyricActivityAttributes>.activities {
            let sent = Sent(a)
            await sent.value.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// ActivityKit's Activity is thread-safe but not declared Sendable, so awaiting its async
    /// methods from this @MainActor class trips Swift 6 region checking. Box it.
    private struct Sent<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
