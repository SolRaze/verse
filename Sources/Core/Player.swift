import AVFoundation
import Observation
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(VLCKit)
import VLCKit          // same API; SPM repackage ships the unified VLCKit module
#endif

/// One engine for everything: local files of any container/codec, and extracted YouTube streams.
///
/// VLC rather than AVPlayer because AVFoundation won't decode opus, ogg, wma, ape, mkv, or avi,
/// and a two-engine split means two now-playing integrations and two sets of bugs.
@MainActor
@Observable
final class Player: NSObject {
    struct Item {
        var url: URL
        var title: String
        var artist: String
        var album: String? = nil
        var artwork: UIImage? = nil
        /// SponsorBlock segments, seconds. Playback jumps to `end` on entering one.
        var skipSegments: [(start: TimeInterval, end: TimeInterval)] = []
        /// Set when the URL is a security-scoped bookmark resolution and must be released.
        var scoped: Bool = false
        /// Stable id for per-track resume position (library item UUID). nil = no resume.
        var resumeKey: String? = nil
    }

    /// Saved position waiting for VLC to learn the duration; applied on the first tick.
    private var pendingResume: TimeInterval?

    /// Position at the last resume write, so the tick can throttle to one write per 5s.
    private var lastResumeWrite: TimeInterval = 0
    /// SponsorBlock toggle, read on load rather than on every tick. Nobody flips it mid-song.
    private var sponsorBlockEnabled = false

    /// Flush the resume position now. Called wherever playback stops advancing, so the throttle
    /// in the tick can never lose more than its window.
    private func writeResumePosition() {
        guard let key = current?.resumeKey, position > 10 else { return }
        UserDefaults.standard.set(position, forKey: "resume." + key)
        lastResumeWrite = position
    }

    /// What the user WANTS (last play/pause), separate from VLC's actual state. If the audio
    /// session dies while backgrounded — a brief interruption, or the app being suspended after
    /// audio stalled — VLC stops but this stays true, so foreground knows to resume.
    private var intendedPlaying = false

    private(set) var current: Item?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var lyrics: Lyrics?

    /// Attach to a SwiftUI UIViewRepresentable to show video. Phone screen only — there is no
    /// route to the CarPlay display and attempting one is wasted effort. See README.
    let videoView = UIView()

    private let vlc = VLCMediaPlayer()
    @ObservationIgnored private lazy var nowPlaying = NowPlaying(commands: .init(
        play: { [weak self] in self?.play() },
        pause: { [weak self] in self?.pause() },
        next: { [weak self] in self?.onNext?() },
        previous: { [weak self] in self?.onPrevious?() },
        seek: { [weak self] t in self?.seek(to: t) }))

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Fired when a track ends on its own (distinct from a manual next), so the queue can honor
    /// repeat-one.
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        vlc.delegate = self
        vlc.drawable = videoView
        // Resume after an interruption ends (phone call, Siri, another app's audio). Without
        // this the session stays deactivated and playback never comes back until relaunch.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            if opts.contains(.shouldResume) {
                MainActor.assumeIsolated { self?.resumePlaybackIfNeeded() }
            }
        }
    }

    /// Must succeed before any playback, or there is no background audio and no CarPlay.
    func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    /// Foreground / interruption-end recovery. The session may have been torn down while we were
    /// suspended, leaving it inactive so nothing plays until relaunch (the "no music unless full
    /// restart" bug). Reactivate it and, if the user meant to be playing, resume — reloading the
    /// media when VLC fully stopped rather than merely paused.
    func resumePlaybackIfNeeded() {
        try? AVAudioSession.sharedInstance().setActive(true)
        guard intendedPlaying, !vlc.isPlaying else { return }
        switch vlc.state {
        case .stopped, .ended, .error:
            guard let item = current else { return }
            let at = position
            vlc.media = VLCMedia(url: item.url)
            pendingResume = at > 10 ? at : nil
            vlc.play()
        default:
            vlc.play()
        }
    }

    /// `autoplay: false` loads the track paused — that is how the last-playing item is restored
    /// into Now Playing on launch. `resumeToSaved` applies the track's saved position; OFF by default so a
    /// normal tap starts from the beginning (only the explicit Resume actions pass true). The
    /// position keeps being SAVED regardless (resumeKey), so Resume/launch have something to use.
    func load(_ item: Item, lyrics: Lyrics?, autoplay: Bool = true, resumeToSaved: Bool = false) {
        stop()
        current = item
        self.lyrics = lyrics

        lastResumeWrite = 0
        sponsorBlockEnabled = UserDefaults.standard.bool(forKey: Pref.sponsorBlock)

        if item.scoped { _ = item.url.startAccessingSecurityScopedResource() }
        vlc.media = VLCMedia(url: item.url)
        // Only resume when asked; >10s in, applied once duration is known.
        pendingResume = resumeToSaved ? item.resumeKey.flatMap {
            let t = UserDefaults.standard.double(forKey: "resume." + $0)
            return t > 10 ? t : nil
        } : nil

        nowPlaying.begin(
            track: .init(title: item.title, artist: item.artist, album: item.album,
                         duration: 0, artwork: item.artwork),
            lyrics: lyrics)
        if autoplay { play() } else { intendedPlaying = false }
        snapshot()
    }

    /// Late attach for lyrics/artwork that resolved after playback started (issue #4: sound
    /// first, network after). No-op if the track changed while resolving.
    func attach(lyrics: Lyrics?, artwork: UIImage?, forURL url: URL) {
        guard current?.url == url else { return }
        if let lyrics { self.lyrics = lyrics }
        // Only first-time artwork republished — keeps the extra widget write off replays.
        let newArt = current?.artwork == nil ? artwork : nil
        if let newArt {
            current?.artwork = newArt
            snapshot()
        }
        nowPlaying.attach(lyrics: lyrics, artwork: newArt)
    }

    /// Widget state. Written on track change and play/pause flips only — never per tick,
    /// widget reloads are budgeted.
    private func snapshot() {
        PlaybackSnapshot.write(
            current.map { PlaybackSnapshot(title: $0.title, artist: $0.artist,
                                           isPlaying: isPlaying, hasArtwork: $0.artwork != nil) }
                ?? PlaybackSnapshot(title: "Nothing playing", artist: "", isPlaying: false, hasArtwork: false),
            artwork: current?.artwork)
    }

    func play() { intendedPlaying = true; vlc.play() }
    func pause() { intendedPlaying = false; writeResumePosition(); vlc.pause() }

    func stop() {
        intendedPlaying = false
        writeResumePosition()
        vlc.stop()
        if let item = current, item.scoped { item.url.stopAccessingSecurityScopedResource() }
        current = nil
        nowPlaying.end()
    }

    func seek(to time: TimeInterval) {
        vlc.time = VLCTime(int: Int32(time * 1000))
        // VLC only ticks while playing — a paused seek must move the UI (lyric highlight,
        // scrubbers) immediately or nothing appears to happen.
        position = time
        lastResumeWrite = time
        nowPlaying.invalidatePublishGate()
        syncNowPlaying()
    }

    private func syncNowPlaying() {
        nowPlaying.update(position: position, duration: duration, playing: isPlaying)
    }

    /// Foreground hook: start a Live Activity that couldn't be created while backgrounded.
    func resumeLiveActivity() { nowPlaying.resumeActivityIfNeeded() }
}

extension Player: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification!) {
        Task { @MainActor in
            position = Double(vlc.time.intValue) / 1000
            duration = Double(vlc.media?.length.intValue ?? 0) / 1000

            // Apply a saved resume once the length is known; near-the-end saves don't resume.
            if let t = pendingResume, duration > 0 {
                pendingResume = nil
                if t < duration * 0.9 { seek(to: t) }
            }
            // Remember position for resume, at most every 5s. VLC ticks ~4x a second and this
            // is only read on resume, so per-tick writes bought nothing. pause/stop/track-change
            // flush it, so no more than 5s of progress is ever lost.
            if position > 10, abs(position - lastResumeWrite) >= 5 { writeResumePosition() }

            // SponsorBlock: entering a segment jumps to its end. That is the whole ad-skip
            // feature. Settings can turn it off. The toggle is read once per track, not per tick.
            if sponsorBlockEnabled,
               let seg = current?.skipSegments.first(where: { position >= $0.start && position < $0.end - 0.5 }) {
                seek(to: seg.end)
                return
            }
            syncNowPlaying()
        }
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification!) {
        Task { @MainActor in
            let was = isPlaying
            isPlaying = vlc.isPlaying
            syncNowPlaying()
            if was != isPlaying { snapshot() }
            if vlc.state == .ended { onFinished?() }
        }
    }
}

extension Player: PlaybackControlling {
    func toggle() { isPlaying ? pause() : play() }
    func nextTrack() { onNext?() }
    func previousTrack() { onPrevious?() }
}
