import AppIntents

/// Compiled into BOTH the app and the widget extension. The widget's buttons need the intent
/// types at compile time, but AudioPlaybackIntent conformance makes the system run perform()
/// in the app process — where `PlaybackBridge.controls` is the live Player. In the widget
/// process the bridge is empty and these are no-ops, which is fine: they never run there.
@MainActor
protocol PlaybackControlling: AnyObject {
    func toggle()
    func nextTrack()
    func previousTrack()
}

@MainActor
final class PlaybackBridge {
    static let shared = PlaybackBridge()
    weak var controls: PlaybackControlling?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    func perform() async throws -> some IntentResult {
        await MainActor.run { PlaybackBridge.shared.controls?.toggle() }
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    func perform() async throws -> some IntentResult {
        await MainActor.run { PlaybackBridge.shared.controls?.nextTrack() }
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    func perform() async throws -> some IntentResult {
        await MainActor.run { PlaybackBridge.shared.controls?.previousTrack() }
        return .result()
    }
}
