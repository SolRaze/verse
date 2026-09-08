import Foundation
import UIKit
import WidgetKit

/// What the widget is allowed to know. The widget extension is a separate process, so anything
/// it renders has to cross an App Group.
///
/// ponytail: JSON + a PNG in the group container. Not a shared database, not XPC — this is four
/// fields and one image, and it's rewritten on track change, not per frame.
struct PlaybackSnapshot: Codable, Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var hasArtwork: Bool

    static let appGroup = "group.com.sol.verse"   // must match project.yml + both targets' entitlements

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
    private static var jsonURL: URL? { container?.appendingPathComponent("nowplaying.json") }
    private static var artURL: URL? { container?.appendingPathComponent("artwork.png") }

    /// Called by the app on track change and on play/pause. NOT per lyric line — widget timeline
    /// reloads are budgeted (a few dozen a day) and per-line reloads get throttled to nothing.
    /// Per-line lyrics belong in a Live Activity. See SPEC.md.
    static func write(_ snapshot: PlaybackSnapshot, artwork: UIImage?) {
        guard let jsonURL else { return }
        try? JSONEncoder().encode(snapshot).write(to: jsonURL)
        if let artURL {
            if let png = artwork?.pngData() {
                try? png.write(to: artURL)
            } else {
                try? FileManager.default.removeItem(at: artURL)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func read() -> PlaybackSnapshot? {
        guard let jsonURL, let data = try? Data(contentsOf: jsonURL) else { return nil }
        return try? JSONDecoder().decode(PlaybackSnapshot.self, from: data)
    }

    static func readArtwork() -> UIImage? {
        guard let artURL, let data = try? Data(contentsOf: artURL) else { return nil }
        return UIImage(data: data)
    }
}
