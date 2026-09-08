import AVKit
import SwiftUI

/// The route that puts video on the CarPlay screen — iOS 26's "AirPlay video in the car".
///
/// This is the ONE place AVPlayer is allowed in this project. AirPlay video works by streaming
/// the media to the receiver, which only AVPlayer's external-playback pipeline can do; VLC
/// decodes and draws locally, so it can never AirPlay video. The split:
///
///   - AVPlayer-compatible container (mp4/m4v/mov/HLS — includes every extracted YouTube
///     stream) -> this player, so "send to car screen" is available.
///   - everything else (mkv/avi/webm/...) -> the VLC `Player`, phone screen only.
///
/// Constraints that are the car's, not ours: the vehicle must support AirPlay video in the car
/// (an MFi feature; factory support is still nearly nonexistent), and playback stops when the
/// car moves. Both enforced by the system — no code here.
@MainActor
@Observable
final class AirPlayVideoPlayer {
    let player = AVPlayer()

    private(set) var isExternal = false   // true while video is on the car / TV
    private(set) var isPlaying = false

    /// SponsorBlock segments for the current item; entering one seeks past it.
    var skipSegments: [(start: TimeInterval, end: TimeInterval)] = []

    private var observation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    init() {
        // Both default-ish, but they ARE the feature — set explicitly so nobody "cleans" them up.
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        observation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] p, _ in
            Task { @MainActor in self?.isExternal = p.isExternalPlaybackActive }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.rate > 0
            Task { @MainActor in self?.isPlaying = playing }
        }
        // 1Hz is plenty for SponsorBlock; segments are tens of seconds long.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let t = time.seconds
                if let seg = self.skipSegments.first(where: { t >= $0.start && t < $0.end - 0.5 }) {
                    self.player.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600))
                }
            }
        }
    }

    func load(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    func stop() { player.replaceCurrentItem(with: nil) }

    /// Containers AVPlayer handles natively, i.e. the ones that can AirPlay to the car.
    static func canAirPlay(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac", "ts"]
            .contains(url.pathExtension.lowercased())
    }
}

/// The AirPlay icon. Tapping it lists the car's display when the head unit supports
/// AirPlay video in the car (and Apple TVs etc. otherwise).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        style(v)
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context _: Context) { style(v) }

    /// A plain white glyph when nothing's connected; the icon only lights (accent, or blue on the
    /// stock white theme) once a route is active. It was inheriting the app tint, so it looked
    /// "on" all the time even with no device connected.
    private func style(_ v: AVRoutePickerView) {
        v.tintColor = .white
        let hex = UserDefaults.standard.string(forKey: Pref.theme) ?? ""
        v.activeTintColor = hex.isEmpty ? .systemBlue : UIColor(Pref.color(for: hex))
    }
}

/// Video surface for the AVPlayer path.
struct AirPlayVideoView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        return vc
    }
    func updateUIViewController(_: AVPlayerViewController, context _: Context) {}
}
