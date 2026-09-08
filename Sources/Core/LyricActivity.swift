import ActivityKit
import Foundation

/// Live Activity payload for per-line lyrics on the Lock Screen (SPEC §6). Compiled into BOTH
/// targets: the app starts/updates the activity, the widget extension renders it.
struct LyricActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var previous: String
        var current: String
        var next: String
        var isPlaying: Bool
    }

    var title: String
    var artist: String
}
