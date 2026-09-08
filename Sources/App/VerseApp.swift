import SwiftUI

@main
struct VerseApp: App {
    // All three are @Observable, so all three are @State.
    @State private var library: LibraryStore
    @State private var playlists = PlaylistStore()
    @State private var coordinator: Coordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Pref.registerDefaults()
        let lib = LibraryStore()
        _library = State(wrappedValue: lib)
        _coordinator = State(wrappedValue: Coordinator(library: lib))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(playlists)
                .environment(coordinator)
                // Foreground: reactivate the audio session (dead after a background suspend/
                // interruption, else nothing plays until relaunch) and start a Live Activity
                // that iOS blocked while backgrounded.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.player.resumePlaybackIfNeeded()
                        coordinator.player.resumeLiveActivity()
                    } else {
                        // Library writes are coalesced now, so the pending one has to land before
                        // iOS can kill us. .inactive as well as .background: the transient case
                        // (control centre, a call) costs one cheap write, missing it costs edits.
                        library.flush()
                        coordinator.flushQueue()
                    }
                }
        }
    }
}
