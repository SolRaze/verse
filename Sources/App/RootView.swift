import SwiftUI

/// The tab shell: Home + Library, with the things that outlive any one screen — the mini player
/// and the player sheet — owned here rather than duplicated per tab.
struct RootView: View {
    @Environment(Coordinator.self) private var coordinator

    enum Tab { case home, library, search }
    @State private var tab: Tab = .home
    @AppStorage(Pref.theme) private var theme = ""
    @AppStorage(Pref.iPodMode) private var iPodMode = false

    var body: some View {
        // @Observable gives no projected value; @Bindable is how a binding is taken from one.
        @Bindable var coordinator = coordinator
        // The accessory is ALWAYS attached (Apple-Music style): the dock must look the
        // same on boot as it does mid-song, so the bar shows a "Not Playing" idle state instead
        // of appearing when playback starts and resizing the dock.
        tabs
            .tabViewBottomAccessory { MiniPlayerBar(player: coordinator.player) }
            .sheet(isPresented: $coordinator.showPlayer) { PlayerView() }
            // iPod mode rides on top; MENU (or the toggle) leaves it.
            .fullScreenCover(isPresented: $iPodMode) {
                IPodView(player: coordinator.player)
            }
            // Here, not on one tab: a play can fail from Home, Search, the queue or the player.
            .overlay { if coordinator.busy { ProgressView().controlSize(.large) } }
            .alert("Something failed", isPresented: .init(
                get: { coordinator.lastError != nil },
                set: { if !$0 { coordinator.lastError = nil } })
            ) { Button("OK", role: .cancel) {} } message: {
                Text(coordinator.lastError ?? "")
            }
            .onOpenURL { coordinator.open(external: $0) }
            .onChange(of: coordinator.deepLink) { _, link in
                if link != nil { tab = .library }
            }
            .tint(Pref.color(for: theme)) // monotone white default; Settings can retint
            .preferredColorScheme(.dark)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Home", systemImage: "house.fill", value: Tab.home) {
                HomeView()
            }
            SwiftUI.Tab("Library", systemImage: "music.note.list", value: Tab.library) {
                LibraryView()
            }
            // Create is NOT in the dock: it's a hidden page — triple-tap the Home title to
            // unlock, then swipe right on Home to open it (see HomeView).
            // Settings pushes from Library's top-left gear — no dock tab.
            // role: .search puts this in the dock's own search pill, Files-app style.
            SwiftUI.Tab(value: Tab.search, role: .search) {
                SearchView()
            }
        }
    }
}

