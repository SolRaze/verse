import SwiftUI
import UIKit

/// The landing tab: a big `Music` title, search under it, then the smart shelves — playlists,
/// most-played albums, most-played tracks. Browsing and importing live in the Library tab.
///
/// "Album" here means a folder that directly holds tracks. This library has no album tag; the
/// folder tree is the organization, so a leaf folder is the closest true thing to an album.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(Coordinator.self) private var coordinator
    // Two zones, two prefs (#2): tiles pack into the 4-column grid and resize, shelves are
    // full-width rows that only reorder. A drag never crosses between them.
    @AppStorage(Pref.homeSections) private var sectionsCSV = HomeLayout.defaultShelvesCSV
    @AppStorage(Pref.homeTiles) private var tilesCSV = HomeLayout.defaultTilesCSV
    @AppStorage(Pref.createUnlocked) private var createUnlocked = false
    @State private var path = NavigationPath()
    @State private var showCreate = false
    @State private var unlockFlash = false
    @State private var infoItem: LibraryItem?
    @State private var editingHome = false
    @State private var showGallery = false

    private let gap: CGFloat = 12
    private let pad: CGFloat = 16
    /// Rows a shelf shows. The per-shelf size pill went with #3 — tiles resize, shelves don't.
    private let shelfRows = 6

    private var tiles: [HomeTile] { HomeLayout.parseTiles(tilesCSV) }
    private var shelves: [String] { HomeLayout.parseShelves(sectionsCSV) }
    private var placed: Set<String> { Set(tiles.map(\.id)).union(shelves) }

    // MARK: mutations

    private func remove(_ id: String) {
        tilesCSV = HomeLayout.tilesCSV(tiles.filter { $0.id != id })
        sectionsCSV = shelves.filter { $0 != id }.joined(separator: ",")
    }

    private func add(_ id: String) {
        switch HomeCatalog.zone(id) {
        case .tile: tilesCSV = HomeLayout.tilesCSV(tiles + [HomeTile(id: id, cols: 2, rows: 2)])
        case .shelf: sectionsCSV = (shelves + [id]).joined(separator: ",")
        case .none: break
        }
    }

    private func moveTile(_ dragged: String, before target: String) {
        let ordered = HomeLayout.move(tiles.map(\.id), dragged, before: target)
        tilesCSV = HomeLayout.tilesCSV(ordered.compactMap { id in tiles.first { $0.id == id } })
    }

    private func moveShelf(_ dragged: String, before target: String) {
        sectionsCSV = HomeLayout.move(shelves, dragged, before: target).joined(separator: ",")
    }

    private func resizeTile(_ tile: HomeTile, dCols: Int, dRows: Int) {
        var list = tiles
        guard let i = list.firstIndex(where: { $0.id == tile.id }) else { return }
        let snapped = HomeLayout.snap(cols: list[i].cols + dCols, rows: list[i].rows + dRows,
                                      for: tile.id)
        list[i].cols = snapped.cols
        list[i].rows = snapped.rows
        tilesCSV = HomeLayout.tilesCSV(list)
    }

    /// Hold enters edit mode directly (#17) — no context-menu step and no button to enter. The
    /// only way out is the Done pill, which is why there is one.
    private func enterEdit() {
        guard !editingHome else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.snappy) { editingHome = true }
    }

    /// One-time move off the old single-list layout, where tiles and shelves shared one ordered
    /// pref. Only runs while the tiles pref has never been written.
    private func migrateLayout() {
        guard UserDefaults.standard.string(forKey: Pref.homeTiles) == nil else { return }
        let moved = HomeLayout.migrate(sectionsCSV: sectionsCSV, tilesCSV: nil)
        tilesCSV = moved.tiles
        sectionsCSV = moved.shelves
    }

    /// Shelf header: name, plus the minus badge while editing. The whole row is the hold target —
    /// without an explicit content shape the press only lands on the glyphs.
    private func shelfHeader(_ id: String) -> some View {
        HStack(spacing: 8) {
            if editingHome { LayoutMinusBadge { remove(id) } }
            Text(HomeCatalog.name(id)).font(.headline)
            Spacer()
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) { enterEdit() }
    }

    /// Control Center's "Add a Control": plain text at the end of the scroll, so entering edit
    /// mode is what reveals it. Replaces the old list of "Add <name>" buttons.
    private var addButton: some View {
        Button { showGallery = true } label: {
            Label("Add Widget", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The cell width comes from a GeometryReader wrapping the scroll view, same as the
            // Create canvas. Measuring the content stack instead reports its intrinsic width
            // (64pt), not the screen's — the tiles came out a fifth of their size.
            GeometryReader { geo in
                let colW = max((geo.size.width - pad * 2 - gap * 3) / 4, 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        tileZone(colW: colW)
                        ForEach(shelves, id: \.self) { id in shelfBlock(id) }
                        // In the flow, not an overlay: as an overlay it drew *behind* the tiles,
                        // which reads as a rendering fault rather than an empty library.
                        emptyState
                        // Always offered once Home is bare: the hold that enters edit mode needs
                        // something to land on, so an edit-mode-only button would strand you.
                        if editingHome || placed.isEmpty { addButton }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, pad)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            // A List can't drag-reorder its sections, which is the whole reason Home is a scroll
            // view now (#2). The hold-to-edit gesture rides the background so rows keep their own
            // context menus — on the content itself both fired at once (#17).
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.45) { enterEdit() }
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: AlbumRef.self) { AlbumPage(album: $0) }
            .navigationDestination(for: LocalPlaylist.self) { LocalPlaylistPage(playlist: $0) }
            .navigationDestination(for: FolderPath.self) { fp in
                FolderView(path: fp.components)
            }
            .navigationDestination(for: RemotePlaylist.self) { pl in
                PlaylistDetailView(playlist: pl)
            }
            .navigationDestination(for: FetchReviewRef.self) { _ in FetchReviewView() }
            // Nothing enters edit mode but the hold (#17). Done is the only pill, and only while
            // editing — iOS's Edit pill opens a wallpaper/layout menu Verse has no equivalent for.
            .toolbar {
                if editingHome {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { withAnimation(.snappy) { editingHome = false } }
                            .buttonStyle(.glass)
                    }
                }
            }
            .sheet(isPresented: $showGallery) {
                LayoutGallerySheet(title: "Add to Home", entries: HomeCatalog.entries,
                                   placed: placed) { add($0); showGallery = false }
            }
            .onAppear(perform: migrateLayout)
            // Hidden Create page. Locked: a triple-tap on the title strip unlocks it (with a
            // brief confirmation). Unlocked: a right-swipe from the left edge opens it.
            .overlay(alignment: .top) { if !createUnlocked { unlockStrip } }
            .overlay(alignment: .top) { if unlockFlash { unlockConfirmation } }
            .simultaneousGesture(revealSwipe)
            .fullScreenCover(isPresented: $showCreate) { CreatePage() }
            .modifier(TrackSheets(infoItem: $infoItem))
            }
        }
    }

    /// A clear band over the large title that only listens for a triple-tap (single taps and
    /// scrolls fall through). Removed once unlocked so it never blocks anything again.
    private var unlockStrip: some View {
        Color.clear.frame(height: 90).contentShape(Rectangle())
            .onTapGesture(count: 3) {
                createUnlocked = true
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                withAnimation { unlockFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { unlockFlash = false }
                }
            }
    }

    private var unlockConfirmation: some View {
        Text("Create unlocked — swipe right")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Left-edge right-swipe opens Create (only once unlocked). Edge-anchored + mostly-horizontal
    /// so it doesn't fight the List's vertical scroll.
    private var revealSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { v in
                guard createUnlocked, v.startLocation.x < 40,
                      v.translation.width > 90, abs(v.translation.height) < 60 else { return }
                showCreate = true
            }
    }

    // MARK: tile zone

    /// The 4-column grid. Greedy packing, same geometry the Create canvas uses — one cell is a
    /// quarter of the content width, so a 1x1 is a square and widening it makes a pill.
    @ViewBuilder private func tileZone(colW: CGFloat) -> some View {
        let packed = HomeLayout.pack(tiles)
        if !packed.isEmpty {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(packed.enumerated()), id: \.offset) { _, row in
                    // Top-aligned: a 2x1 beside a 2x2 sits at the top of the row, not floating in
                    // the middle of it.
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(row) { tile in tileView(tile, colW: colW) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func tileView(_ tile: HomeTile, colW: CGFloat) -> some View {
        let width = colW * CGFloat(tile.cols) + gap * CGFloat(tile.cols - 1)
        let height = colW * CGFloat(tile.rows) + gap * CGFloat(tile.rows - 1)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return tileBody(tile)
            // Editing owns every touch inside a tile — otherwise a drag to reorder lands as a tap
            // on whatever button sits under the finger.
            .allowsHitTesting(!editingHome)
            .frame(width: width, height: height)
            .background(.white.opacity(0.06), in: shape)
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                if editingHome { LayoutMinusBadge { remove(tile.id) }.offset(x: -8, y: -8) }
            }
            // Bottom-right curved corner, snapping to the presets (#3). The size pill is gone.
            .overlay(alignment: .bottomTrailing) {
                if editingHome {
                    ResizeBumper(colStep: colW + gap, rowStep: colW + gap) { dCols, dRows in
                        withAnimation(.snappy) { resizeTile(tile, dCols: dCols, dRows: dRows) }
                    }
                    .offset(x: 5, y: 5)
                }
            }
            .onLongPressGesture(minimumDuration: 0.45) { enterEdit() }
            .modifier(ReorderDrag(id: tile.id, active: editingHome) { moveTile($0, before: tile.id) })
    }

    @ViewBuilder private func tileBody(_ tile: HomeTile) -> some View {
        switch tile.id {
        case "now":
            // Always present, idle or not (#8) — the dimmed "Not Playing" state is the mini
            // player's, and hiding the tile would also hide it from edit mode.
            NowPlayingCard(player: coordinator.player, size: tileDensity(tile))
                // A one-row tile is 174pt wide; 12pt of inset either side is the difference
                // between a readable title and an ellipsis.
                .padding(tile.rows > 1 ? 12 : 8)
        case "albums":
            albumsTile(tile)
        case "fetch":
            fetchTile(tile)
        default:
            EmptyView()
        }
    }

    /// Live fetch status (#5): what the review list would say, without opening it. Reads the same
    /// `reviewState`, so the tile and the list can never disagree. Tapping opens the list.
    @ViewBuilder private func fetchTile(_ tile: HomeTile) -> some View {
        let tally = library.fetchTally()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if library.rescanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checklist").font(.footnote).foregroundStyle(.tint)
                }
                if tile.cols > 1 {
                    Text("Fetch").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if library.rescanning {
                Text(library.rescanStatus.isEmpty ? "Working…" : library.rescanStatus)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text(tile.cols > 1 ? tally.headline : "\(tally.attention)")
                    .font(tile.cols > 1 ? .subheadline.weight(.semibold) : .title2.weight(.semibold))
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            // The per-state breakdown only fits the 2x2; below that the headline is the whole tile.
            if tile.rows > 1, !library.rescanning {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(FetchState.allCases) { state in
                        let n = tally.count(state)
                        if n > 0 {
                            HStack(spacing: 6) {
                                Circle().fill(state.tint).frame(width: 7, height: 7)
                                Text("\(n) \(state.rawValue.lowercased())")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { path.append(FetchReviewRef()) }
    }

    /// Tile spans map onto the card's densities. A one-row tile takes "small": "medium" adds the
    /// wave pill and a bigger cover, which at two cells wide squeezed the title down to a
    /// one-character column.
    private func tileDensity(_ tile: HomeTile) -> String {
        tile.rows > 1 ? "large" : "small"
    }

    /// Most-played albums as covers only — the shelf's captions don't survive a 1x1, and the cover
    /// is what identifies an album anyway. One cover per cell.
    @ViewBuilder private func albumsTile(_ tile: HomeTile) -> some View {
        let _ = library.artworkVersion
        let albums = library.mostPlayedAlbums().prefix(tile.cols * tile.rows).map { $0 }
        let cols = tile.rows > 1 ? tile.cols : max(tile.cols, 1)
        VStack(alignment: .leading, spacing: 6) {
            if tile.cols > 1 {
                Text("Most Played").font(.caption2).foregroundStyle(.secondary)
            }
            if albums.isEmpty {
                Image(systemName: "square.stack")
                    .font(.title2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols),
                          spacing: 6) {
                    ForEach(albums, id: \.name) { album in
                        Button { path.append(AlbumRef(name: album.name)) } label: {
                            albumCover(album.name)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { albumMenu(album.name) }
                    }
                }
            }
        }
        .padding(10)
    }

    // MARK: shelf zone

    @ViewBuilder private func shelfBlock(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader(id)
            switch id {
            case "playlists": playlistsShelf
            case "tracks": trackShelf(library.mostPlayedTracks(limit: shelfRows))
            case "recentAdded":
                trackShelf(library.items
                    .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
                    .prefix(shelfRows).map { $0 })
            case "recentPlayed":
                trackShelf(library.items.filter { $0.lastPlayed != nil }
                    .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
                    .prefix(shelfRows).map { $0 })
            default: EmptyView()
            }
        }
        .modifier(ReorderDrag(id: id, active: editingHome) { moveShelf($0, before: id) })
    }

    /// The inset card by hand: same fill and hairlines a `List` draws, without the list.
    private func shelfCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private func shelfRow<V: View>(_ index: Int, @ViewBuilder _ row: () -> V) -> some View {
        if index > 0 { Divider().overlay(.white.opacity(0.12)).padding(.leading, 14) }
        row().padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var playlistsShelf: some View {
        let shown = playlists.playlists.prefix(shelfRows).map { $0 }
        if !shown.isEmpty {
            shelfCard {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, pl in
                    shelfRow(index) {
                        NavigationLink(value: pl) { PlaylistRow(playlist: pl) }
                            .tint(.primary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func trackShelf(_ items: [LibraryItem]) -> some View {
        if !items.isEmpty {
            shelfCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    shelfRow(index) {
                        Button { coordinator.play(item, in: items) } label: {
                            ItemRow(item: item).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .tint(.primary)
                        .contextMenu { ItemContextMenu(item: item, queue: items, infoItem: $infoItem) }
                    }
                }
            }
        }
    }

    /// Hold menu for an album tile: play or shuffle its tracks, or open it.
    @ViewBuilder private func albumMenu(_ name: String) -> some View {
        let tracks = library.items.filter { $0.albumKey == name }
        Button { if let f = tracks.first { coordinator.play(f, in: tracks) } } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { if let f = tracks.randomElement() { coordinator.play(f, in: tracks.shuffled()) } } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        Button { path.append(AlbumRef(name: name)) } label: {
            Label("Open Album", systemImage: "square.stack")
        }
    }

    /// Two-up grid of most-played albums.
    /// Read `artworkVersion` at the call site too, not only in here — the helper's read alone
    /// does not reliably register the dependency.
    private func albumCover(_ name: String) -> some View {
        let _ = library.artworkVersion
        let src = library.items.first {
            $0.albumKey == name && Artwork.hasArt(for: $0.id.uuidString)
        }
        return Group {
            if let src, let img = Artwork.image(for: src.id.uuidString) {
                Image(uiImage: img).resizable().aspectRatio(1, contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Image(systemName: "square.stack").foregroundStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Two different empty states: an empty library is a "go import something" problem, a library
    /// nobody has played yet is just waiting on data.
    @ViewBuilder private var emptyState: some View {
        if playlists.playlists.isEmpty,
           library.mostPlayedAlbums().isEmpty, library.mostPlayedTracks().isEmpty {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet", systemImage: "music.note",
                        description: Text("Import a folder or paste a link from the Library tab."))
                } else {
                    ContentUnavailableView(
                        "Nothing played yet", systemImage: "play.circle",
                        description: Text("Play something and your most-played albums and tracks show up here."))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            // Explains the library, doesn't act on it — and swallowing the hold was what stranded
            // a bare Home with no way back into edit mode.
            .allowsHitTesting(false)
        }
    }
}

/// Widget-shaped Now Playing card, shared by Home and the Queue sheet: cover, title,
/// play/pause, and the wave scrubber in a pill beneath (real audio when decodable).
struct NowPlayingCard: View {
    @Environment(Coordinator.self) private var coordinator
    let player: Player
    /// "small" = one compact row, no scrubber. "medium" = row + scrubber pill.
    /// "large" = big cover on top, widget-large spirit.
    var size: String = "medium"
    @State private var samples: [Float]?

    /// Same idle test the mini player uses, so the two never disagree about what "playing" means.
    private var idle: Bool { coordinator.nowTitle.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if size == "large" {
                Button { coordinator.showPlayer = true } label: {
                    artView
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .opacity(idle ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(idle)
            }
            Button { coordinator.showPlayer = true } label: {
                HStack(spacing: 12) {
                    if size != "large" {
                        artView
                            .frame(width: size == "small" ? 40 : 56,
                                   height: size == "small" ? 40 : 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .opacity(idle ? 0.4 : 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if size != "small" {
                            Text("Now Playing").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(idle ? "Not Playing" : coordinator.nowTitle)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                            // Shrinks rather than ellipsing in a 2x1 Home tile, where the text
                            // column is about 60pt.
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        if !idle, !coordinator.nowArtist.isEmpty {
                            Text(coordinator.nowArtist)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying
                            ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: size == "small" ? 28 : 36))
                    }
                    .buttonStyle(.plain)
                    .disabled(idle)
                }
            }
            .tint(.primary)
            .disabled(idle)

            // Nothing loaded means no waveform and no position to scrub — the pill would just be
            // an inert bar, so it sits out the idle state entirely.
            if size != "small", !idle, coordinator.engine == .vlc {
                WaveScrubber(samples: samples,
                             position: player.position,
                             duration: player.duration) { player.seek(to: $0) }
                    .frame(height: 18)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    // Glass, matching the lyrics screen's wave pill — every wave scrubber in the
                    // app reads the same (07-25).
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .opacity(idle ? 0.7 : 1)
        .task(id: player.current?.url) {
            samples = nil
            if let url = player.current?.url { samples = await Waveform.load(url: url) }
        }
    }

    @ViewBuilder private var artView: some View {
        if let art = player.current?.artwork {
            Image(uiImage: art).resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }
}

/// The dock's search pill (Files-app style). Flat title/artist match.
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if !search.isEmpty {
                    let q = search.lowercased()
                    let hits = library.items.filter {
                        $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
                    }
                    Section("Results") {
                        ForEach(hits) { item in
                            Button { coordinator.play(item, in: hits) } label: { ItemRow(item: item) }
                                .tint(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            // System placement only. A drawer-pinned field fights the search tab's own bottom
            // field (two fields, clear button desyncs); the earlier "bad circle" was that fight,
            // not the minimize. SearchTests drives type -> clear -> retype to keep this honest.
            .searchable(text: $search)
        }
    }
}
