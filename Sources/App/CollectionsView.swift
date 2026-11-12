import SwiftUI

/// The Apple-Music-shaped Library collections: Playlists / Artists / Albums / Songs
/// rows at the top of Library, each opening a big-title page with a sort menu top right.

enum CollectionKind: String, CaseIterable, Hashable {
    case playlists = "Playlists"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case favourites = "Favourites"

    /// Stable key for `Pref.librarySections` — the display name may change, this can't.
    var id: String { rawValue.lowercased() }

    var icon: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .favourites: "heart"
        }
    }
}

/// Navigation value for an artist page.
struct ArtistRef: Hashable { let name: String }

/// Hold-menu plumbing shared by every track list outside LibraryView: the Info sheet the
/// shared ItemContextMenu drives.
struct TrackSheets: ViewModifier {
    @Binding var infoItem: LibraryItem?

    func body(content: Content) -> some View {
        content.sheet(item: $infoItem) { InfoSheet(item: $0) }
    }
}

/// Navigation value for an album page. `name` is a `LibraryItem.albumKey`.
struct AlbumRef: Hashable { let name: String }

/// Album list row: real cover from any track in the album, name + track count.
struct AlbumRow: View {
    @Environment(LibraryStore.self) private var library
    let name: String
    let artwork: LibraryItem?
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            let _ = library.artworkVersion
            Group {
                if let item = artwork, let img = Artwork.thumb(for: item.id.uuidString) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                        .overlay(Image(systemName: "square.stack").foregroundStyle(.secondary))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(itemCountText(count)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One cell of the albums/artists grid (#16): square cover, name, subtitle. Artists get a circle,
/// which is the only thing distinguishing the two grids at a glance.
struct CollectionTile: View {
    @Environment(LibraryStore.self) private var library
    let name: String
    let subtitle: String
    let artwork: LibraryItem?
    let icon: String
    var circular = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let _ = library.artworkVersion   // re-render when a fetched cover lands
            Group {
                if let item = artwork, let img = Artwork.image(for: item.id.uuidString) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: icon).font(.title2).foregroundStyle(.secondary))
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))

            Text(name).font(.footnote.weight(.medium)).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct CollectionPage: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(Coordinator.self) private var coordinator
    let kind: CollectionKind

    enum Sort: String, CaseIterable, Identifiable {
        case title = "Title", dateAdded = "Date Added", lastPlayed = "Last Played"
        case mostPlayed = "Most Played", artist = "Artist"
        var id: String { rawValue }

        /// Artist ordering only means something where rows have one artist to speak of.
        static func cases(for kind: CollectionKind) -> [Sort] {
            kind == .artists ? [.title] : allCases
        }
    }

    /// How songs break into sections (#16). Albums and artists section themselves.
    enum Grouping: String, CaseIterable, Identifiable {
        case none = "None", album = "Album", artist = "Artist"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .title
    @State private var infoItem: LibraryItem?
    @State private var renamingPlaylist: LocalPlaylist?
    @State private var playlistName = ""

    /// Per-collection, remembered (#16). `@AppStorage` needs a literal key at init, so these are
    /// wired up in `init` from the kind rather than declared with one.
    @AppStorage private var columns: Int
    @AppStorage private var groupingRaw: String

    init(kind: CollectionKind) {
        self.kind = kind
        _columns = AppStorage(wrappedValue: 2, Pref.collectionColumns(kind.id))
        _groupingRaw = AppStorage(wrappedValue: Grouping.none.rawValue,
                                  Pref.collectionGrouping(kind.id))
    }

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .none }

    /// Songs and favourites stay lists — a grid of text rows reads worse than a list.
    private var gridCapable: Bool { kind == .albums || kind == .artists }

    var body: some View {
        Group {
            if gridCapable {
                ScrollView { collectionGrid }
            } else {
                List {
                    switch kind {
                    case .playlists: playlistRows
                    case .songs: songRows(library.items)
                    case .favourites: songRows(library.items.filter(\.liked))
                    case .artists, .albums: EmptyView()   // grid path above
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(kind.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Playlists sort by title only; the play-count sorts mean nothing for them.
            if kind == .playlists {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { library.newPlaylist() } label: { Image(systemName: "plus") }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.cases(for: kind)) { Text($0.rawValue).tag($0) }
                        }
                        // Density and grouping live in the same menu the sort already uses (#16),
                        // rather than adding a second toolbar control.
                        if gridCapable {
                            Divider()
                            Picker("Columns", selection: $columns) {
                                Text("2 Columns").tag(2)
                                Text("3 Columns").tag(3)
                            }
                        }
                        if kind == .songs || kind == .favourites {
                            Divider()
                            Picker("Group By", selection: $groupingRaw) {
                                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0.rawValue) }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
        }
        .overlay { emptyState }
        .modifier(TrackSheets(infoItem: $infoItem))
        .alert("Rename Playlist", isPresented: .init(
            get: { renamingPlaylist != nil }, set: { if !$0 { renamingPlaylist = nil } })
        ) {
            TextField("Name", text: $playlistName)
            Button("Rename") {
                if let pl = renamingPlaylist { library.renamePlaylist(pl, to: playlistName) }
                renamingPlaylist = nil
            }
            Button("Cancel", role: .cancel) { renamingPlaylist = nil }
        }
    }

    // MARK: rows

    @ViewBuilder private var playlistRows: some View {
        // User playlists first, then the scraped remote ones.
        ForEach(library.localPlaylists) { pl in
            NavigationLink(value: pl) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pl.name)
                        Text(itemCountText(pl.itemIDs.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "music.note.list").foregroundStyle(.tint)
                }
            }
            .swipeActions {
                Button(role: .destructive) { library.removePlaylist(pl) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button { playlistName = pl.name; renamingPlaylist = pl } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) { library.removePlaylist(pl) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        ForEach(playlists.playlists.sorted { $0.title < $1.title }) { pl in
            NavigationLink(value: pl) { PlaylistRow(playlist: pl) }
                .swipeActions {
                    Button(role: .destructive) { playlists.remove(pl) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
        }
    }

    // MARK: grid

    /// Albums and artists as a 2- or 3-up grid (#16), sectioned. Artists section by first letter
    /// ("parts"); albums section by artist when sorted that way, and sit in one run otherwise.
    @ViewBuilder private var collectionGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
        LazyVGrid(columns: cols, spacing: 16, pinnedViews: [.sectionHeaders]) {
            ForEach(gridSections, id: \.title) { section in
                Section {
                    ForEach(section.tiles, id: \.name) { tile in
                        // Concrete value types, not a type-erased one: `navigationDestination`
                        // matches on the static type, so an AnyHashable here would push a value
                        // nothing is registered to handle and the tap would do nothing.
                        if kind == .artists {
                            NavigationLink(value: ArtistRef(name: tile.name)) { cell(tile) }
                                .tint(.primary)
                        } else {
                            NavigationLink(value: AlbumRef(name: tile.name)) { cell(tile) }
                                .tint(.primary)
                        }
                    }
                } header: {
                    if !section.title.isEmpty {
                        HStack {
                            Text(section.title).font(.title3.weight(.bold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .background(.bar)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func cell(_ tile: Tile) -> some View {
        CollectionTile(name: tile.name, subtitle: tile.subtitle, artwork: tile.artwork,
                       icon: kind.icon, circular: kind == .artists)
    }

    /// One grid cell's data, flattened so albums and artists share a single render path.
    private struct Tile {
        let name: String
        let subtitle: String
        let artwork: LibraryItem?
    }

    private struct GridSection { let title: String; let tiles: [Tile] }

    private var gridSections: [GridSection] {
        kind == .artists ? artistSections : albumSections
    }

    /// Section letter for a name — first letter uppercased, everything else (digits, symbols,
    /// a name that's all whitespace) under "#". Static and pure so it's testable.
    static func sectionLetter(for name: String) -> String {
        let first = name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
        return first.first?.isLetter == true ? first : "#"
    }

    /// Sort order for those letters: A–Z, then "#" last.
    static func sectionLettersSorted(_ letters: [String]) -> [String] {
        letters.sorted { a, b in
            if (a == "#") != (b == "#") { return b == "#" }
            return a < b
        }
    }

    /// Every artist in display order, with its track count and the item whose cover stands for it.
    ///
    /// One grouping pass and each row reads out of it. This filtered all items once per artist
    /// name before, so it was O(items × artists) and re-ran on every body evaluation — the same
    /// shape `albumSections` below was already using. `Dictionary(grouping:)` keeps source order
    /// inside a group, so `.first` still picks the item `items.first { $0.artist == name }` did.
    /// Static and pure so that identity is testable.
    static func artistRows(_ items: [LibraryItem]) -> [(name: String, count: Int,
                                                        artwork: LibraryItem?)] {
        let byArtist = Dictionary(grouping: items.filter { !$0.artist.isEmpty }, by: \.artist)
        return byArtist.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (name: $0, count: byArtist[$0]?.count ?? 0, artwork: byArtist[$0]?.first) }
    }

    /// Artists "sectioned by parts" — first letter, digits and symbols collected under #.
    private var artistSections: [GridSection] {
        let rows = Self.artistRows(library.items)
        let buckets = Dictionary(grouping: rows) { Self.sectionLetter(for: $0.name) }
        return Self.sectionLettersSorted(Array(buckets.keys)).map { letter in
            GridSection(title: letter, tiles: (buckets[letter] ?? []).map { row in
                Tile(name: row.name, subtitle: itemCountText(row.count), artwork: row.artwork)
            })
        }
    }

    /// Album = the embedded album tag (auto-read on import), falling back to the containing
    /// folder for tagless files. Loose file imports thus still gather into their album.
    private var albumSections: [GridSection] {
        let groups = Dictionary(grouping: library.items.filter { !$0.albumKey.isEmpty },
                                by: \.albumKey)
        func plays(_ name: String) -> Int { groups[name]?.reduce(0) { $0 + $1.playCount } ?? 0 }
        func artist(_ name: String) -> String {
            let names = Set((groups[name] ?? []).map(\.artist).filter { !$0.isEmpty })
            return names.count == 1 ? names.first! : names.isEmpty ? "Unknown Artist"
                                                                  : "Various Artists"
        }
        func tile(_ name: String) -> Tile {
            Tile(name: name, subtitle: artist(name), artwork: groups[name]?.first)
        }

        // Sorting by artist sections by artist too — that's what makes the sort readable at a
        // glance instead of just reshuffling one long run.
        if sort == .artist {
            let byArtist = Dictionary(grouping: groups.keys, by: artist)
            return byArtist.keys
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { a in
                    GridSection(title: a, tiles: (byArtist[a] ?? [])
                        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                        .map(tile))
                }
        }
        func newest(_ name: String, _ date: KeyPath<LibraryItem, Date?>) -> Date {
            groups[name]?.compactMap { $0[keyPath: date] }.max() ?? .distantPast
        }
        let alphabetical = groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        // An album's date is its most recent track's. The stable sort keeps the alphabetical
        // order among albums that tie, which is every unplayed one under Last Played.
        let names: [String] = switch sort {
        case .mostPlayed: alphabetical.sorted { plays($0) > plays($1) }
        case .dateAdded: alphabetical.sorted { newest($0, \.dateAdded) > newest($1, \.dateAdded) }
        case .lastPlayed: alphabetical.sorted { newest($0, \.lastPlayed) > newest($1, \.lastPlayed) }
        case .title, .artist: alphabetical
        }
        return [GridSection(title: "", tiles: names.map(tile))]
    }

    /// Songs stay a list (#16), optionally sectioned by album or by artist. The play queue is the
    /// whole sorted run, not the section — starting a song mid-list should keep playing past the
    /// end of its album.
    @ViewBuilder private func songRows(_ items: [LibraryItem]) -> some View {
        let songs = sortedItems(items)
        switch grouping {
        case .none:
            ForEach(songs) { item in songButton(item, queue: songs) }
        case .album, .artist:
            let key: (LibraryItem) -> String = grouping == .album
                ? { $0.albumKey.isEmpty ? "Unknown Album" : $0.albumKey }
                : { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
            let buckets = Dictionary(grouping: songs, by: key)
            ForEach(buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                    id: \.self) { name in
                Section(name) {
                    ForEach(buckets[name] ?? []) { item in songButton(item, queue: songs) }
                }
            }
        }
    }

    private func songButton(_ item: LibraryItem, queue: [LibraryItem]) -> some View {
        Button { coordinator.play(item, in: queue) } label: { ItemRow(item: item) }
            .tint(.primary)
            .contextMenu { ItemContextMenu(item: item, queue: queue, infoItem: $infoItem) }
    }

    // MARK: sorting

    private func plays(_ path: [String]) -> Int {
        library.children(of: path).items.reduce(0) { $0 + $1.playCount }
    }

    private func sortedItems(_ items: [LibraryItem]) -> [LibraryItem] {
        switch sort {
        // Numeric-aware so numbered tracks run 1, 2, … 10 in order.
        case .title: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded: items.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .lastPlayed: items.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .mostPlayed: items.sorted { $0.playCount > $1.playCount }
        case .artist: items.sorted {
            let (a, b) = ($0.artist, $1.artist)
            if a.caseInsensitiveCompare(b) != .orderedSame {
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let empty = switch kind {
        case .playlists: playlists.playlists.isEmpty && library.localPlaylists.isEmpty
        case .artists: !library.items.contains { !$0.artist.isEmpty }
        case .albums: !library.items.contains { !$0.albumKey.isEmpty }
        case .songs: library.items.isEmpty
        case .favourites: !library.items.contains(where: \.liked)
        }
        if empty {
            ContentUnavailableView("Nothing here yet", systemImage: kind.icon,
                                   description: Text(kind == .favourites
                                       ? "Like a song from the player and it will appear here."
                                       : "Import music and it will appear here."))
        }
    }
}

/// One artist's tracks, Home-shaped: big title + the same sort menu.
/// A user playlist: Play/Shuffle header, tracks with the shared hold menu, swipe to remove.
struct LocalPlaylistPage: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let playlist: LocalPlaylist
    @State private var infoItem: LibraryItem?

    private var current: LocalPlaylist {
        library.localPlaylists.first { $0.id == playlist.id } ?? playlist
    }

    var body: some View {
        let tracks = library.tracks(of: current)
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        if let f = tracks.first { coordinator.play(f, in: tracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    Button {
                        if let f = tracks.randomElement() {
                            coordinator.play(f, in: tracks.shuffled())
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .buttonStyle(.glass)
                .disabled(tracks.isEmpty)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                if tracks.isEmpty {
                    Text("Hold any song and pick Add to Playlist.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(tracks) { item in
                    Button { coordinator.play(item, in: tracks) } label: { ItemRow(item: item) }
                        .tint(.primary)
                        .listRowInsets(.init(top: 2, leading: 20, bottom: 2, trailing: 20))
                        .swipeActions {
                            Button(role: .destructive) {
                                library.remove(item, from: current)
                            } label: { Label("Remove", systemImage: "minus.circle") }
                        }
                        .contextMenu {
                            ItemContextMenu(item: item, queue: tracks, infoItem: $infoItem)
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(TrackSheets(infoItem: $infoItem))
    }
}

/// Artist profile page (same shape as AlbumPage): round portrait from any track's art, name,
/// counts, Play/Shuffle, the artist's albums, then their songs with the shared hold menu.
struct ArtistPage: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let artist: ArtistRef
    @State private var infoItem: LibraryItem?
    @State private var portrait: UIImage?

    private var tracks: [LibraryItem] {
        library.items.filter { $0.artist == artist.name }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var albums: [String] {
        Set(tracks.map(\.albumKey).filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            Section {
                VStack(spacing: 10) {
                    // Real profile photo (Deezer, cached) — album pages show covers, artist
                    // pages show the artist. Track art only as a stopgap while it loads.
                    Group {
                        if let portrait {
                            Image(uiImage: portrait).resizable().scaledToFill()
                        } else if let src = tracks.first(where: { Artwork.hasArt(for: $0.id.uuidString) }),
                                  let img = Artwork.image(for: src.id.uuidString) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Circle().fill(.quaternary)
                                .overlay(Image(systemName: "music.mic")
                                    .font(.largeTitle).foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 160, height: 160)
                    .clipShape(Circle())
                    .task {
                        let key = "artist-" + artist.name
                        portrait = Artwork.image(for: key)
                        if portrait == nil,
                           let img = await MetadataScraper.artistImage(named: artist.name) {
                            Artwork.store(image: img, key: key)
                            portrait = img
                        }
                    }

                    Text(artist.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text([albums.isEmpty ? "" : "\(albums.count) album\(albums.count == 1 ? "" : "s")",
                          itemCountText(tracks.count)].filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            if let f = tracks.first { coordinator.play(f, in: tracks) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        Button {
                            if let f = tracks.randomElement() {
                                coordinator.play(f, in: tracks.shuffled())
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums, id: \.self) { name in
                        NavigationLink(value: AlbumRef(name: name)) {
                            AlbumRow(name: name,
                                     artwork: tracks.first { $0.albumKey == name },
                                     count: tracks.filter { $0.albumKey == name }.count)
                        }
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            Section("Songs") {
                ForEach(tracks) { item in
                    Button { coordinator.play(item, in: tracks) } label: { ItemRow(item: item) }
                        .tint(.primary)
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .contextMenu {
                            ItemContextMenu(item: item, queue: tracks, infoItem: $infoItem)
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(TrackSheets(infoItem: $infoItem))
    }
}

/// Album detail: big cover on top, name/artist/count, play + shuffle, then the tracks in
/// sequential (numeric-aware) order — Apple Music album-page shape.
struct AlbumPage: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let album: AlbumRef
    @State private var infoItem: LibraryItem?
    @State private var albumSheet: AlbumSheet?

    enum AlbumSheet: String, Identifiable { case metadata, artwork, edit; var id: String { rawValue } }

    /// Tracks grouped by disc — one group (disc 0) when the album is single-disc, one per disc
    /// otherwise, so multi-disc albums read as "Disc 1 / Disc 2".
    private var discGroups: [(disc: Int, tracks: [LibraryItem])] {
        let t = tracks
        let discs = Set(t.compactMap(\.discNumber))
        guard discs.count > 1 else { return [(0, t)] }
        return Dictionary(grouping: t, by: { $0.discNumber ?? 1 })
            .sorted { $0.key < $1.key }
            .map { (disc: $0.key, tracks: $0.value) }
    }

    private var tracks: [LibraryItem] {
        // Disc/track order once the online lookup has filled numbers; numeric-aware title order
        // (nil numbers sort last) before that.
        library.items.filter { $0.albumKey == album.name }
            .sorted {
                let a = ($0.discNumber ?? 1, $0.trackNumber ?? .max)
                let b = ($1.discNumber ?? 1, $1.trackNumber ?? .max)
                if a != b { return a < b }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private var artistLine: String {
        let names = Array(Set(tracks.map(\.artist).filter { !$0.isEmpty }))
        return names.count == 1 ? names[0] : names.isEmpty ? "" : "Various Artists"
    }

    /// The album's most recently played track, if any has been played — the Resume target.
    private func lastPlayed(_ tracks: [LibraryItem]) -> LibraryItem? {
        tracks.filter { $0.lastPlayed != nil }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            Section {
                VStack(spacing: 10) {
                    let _ = library.artworkVersion
                    Group {
                        if let src = tracks.first(where: { Artwork.hasArt(for: $0.id.uuidString) }),
                           let img = Artwork.image(for: src.id.uuidString) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                                .overlay(Image(systemName: "square.stack")
                                    .font(.largeTitle).foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text(album.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text([artistLine, itemCountText(tracks.count)].filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            if let f = tracks.first { coordinator.play(f, in: tracks) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        Button {
                            if let f = tracks.randomElement() {
                                coordinator.play(f, in: tracks.shuffled())
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                    .buttonStyle(.glass)

                    // Resume: only on the single most-recently-played album (#5), picking up its
                    // last track at the saved spot.
                    if let last = lastPlayed(tracks), album.name == library.mostRecentAlbumKey {
                        Button { coordinator.play(last, in: tracks, resume: true) } label: {
                            Label("Resume \(last.title)", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity).padding(.vertical, 8).lineLimit(1)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            let groups = discGroups
            ForEach(groups, id: \.disc) { group in
                Section {
                    trackRows(group.tracks, in: tracks)
                } header: {
                    if groups.count > 1 {
                        Text("Disc \(group.disc) · \(itemCountText(group.tracks.count))")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { albumSheet = .edit } label: {
                        Label("Edit Album Metadata", systemImage: "pencil")
                    }
                    Divider()
                    Button { albumSheet = .metadata } label: {
                        Label("Find Metadata", systemImage: "text.magnifyingglass")
                    }
                    Button { albumSheet = .artwork } label: {
                        Label("Find Artwork", systemImage: "photo")
                    }
                    // Bare dots, matching the Library options menu (#15) — this one wore a circle.
                } label: { Image(systemName: "ellipsis") }
                    .disabled(library.rescanning)
            }
        }
        .sheet(item: $albumSheet) { sheet in
            switch sheet {
            case .metadata: AlbumFinderSheet(albumName: album.name)
            case .artwork: AlbumArtworkFinderSheet(albumName: album.name)
            case .edit: EditAlbumSheet(albumName: album.name)
            }
        }
        .modifier(TrackSheets(infoItem: $infoItem))
    }

    /// One disc's rows. `queue` is the full album so play/queue spans discs.
    @ViewBuilder private func trackRows(_ rows: [LibraryItem], in queue: [LibraryItem]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
            Button { coordinator.play(item, in: queue) } label: {
                HStack(spacing: 10) {
                    Text("\(item.trackNumber ?? i + 1)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing).monospacedDigit()
                    Text(item.title).lineLimit(1)
                    Spacer()
                    if coordinator.nowPlayingItemID == item.id {
                        Image(systemName: "waveform").foregroundStyle(.tint)
                    }
                }
            }
            .tint(.primary)
            .listRowInsets(.init(top: 6, leading: 20, bottom: 6, trailing: 20))
            .contextMenu {
                ItemContextMenu(item: item, queue: queue, infoItem: $infoItem)
            }
        }
    }
}

/// Album-level metadata editing (#15), reached from the album page's ••• menu. `EditItemSheet` is
/// per track; retyping the album name on twelve tracks is the thing this saves.
///
/// Same freeze rule as the per-track editor: a field is written (and frozen against online
/// metadata) only when the user actually changed it, so leaving Artist alone on a compilation
/// doesn't stamp one artist across every track.
struct EditAlbumSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let albumName: String

    @State private var name = ""
    @State private var artist = ""
    /// What the fields held on open — same "freeze only what changed" test `EditItemSheet` uses.
    @State private var originalName = ""
    @State private var originalArtist = ""

    private var tracks: [LibraryItem] { library.items.filter { $0.albumKey == albumName } }

    /// Blank when the tracks disagree, so saving an untouched field can't flatten a compilation.
    private var sharedArtist: String {
        let names = Set(tracks.map(\.artist).filter { !$0.isEmpty })
        return names.count == 1 ? names.first! : ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Album", text: $name)
                    TextField("Artist", text: $artist, prompt: Text(artistPrompt))
                } footer: {
                    Text("Applies to all \(tracks.count) tracks. A field you edit here stops being "
                         + "overwritten by online metadata.")
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .themedTint()
        .onAppear {
            name = albumName
            artist = sharedArtist
            originalName = name
            originalArtist = artist
        }
    }

    private var artistPrompt: String {
        sharedArtist.isEmpty && !tracks.isEmpty ? "Various Artists" : "Artist"
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let renamed = !trimmedName.isEmpty && trimmedName != originalName
        let reartisted = artist != originalArtist
        for var item in tracks {
            if renamed {
                item.album = trimmedName
                item.frozenFields.insert(MetaField.album.rawValue)
            }
            if reartisted {
                item.artist = artist
                item.frozenFields.insert(MetaField.artist.rawValue)
            }
            if renamed || reartisted { library.update(item) }
        }
        // ponytail: renaming leaves the pushed AlbumPage bound to the old name, so it empties out
        // until you back out and reopen. Ceiling — AlbumRef is the navigation value and a value
        // can't rewrite itself. Upgrade: key the page by a stable album id instead of its name.
        dismiss()
    }
}

/// Sort orders the finder search bar offers (#6e).
/// Not every case suits every surface — album finders offer album/artist/year, the lyrics finder
/// offers title/artist/duration — so each sheet passes the subset it wants rather than relying on
/// `allCases`.
enum FinderSort: String, CaseIterable, Identifiable {
    case relevance = "Relevance", album = "Album", artist = "Artist", year = "Year"
    case title = "Title", duration = "Duration"
    var id: String { rawValue }

    static let albumOptions: [FinderSort] = [.relevance, .album, .artist, .year]
    static let songOptions: [FinderSort] = [.relevance, .title, .artist, .duration]

    /// Relevance is the service's own ranking, so it means "leave the order alone".
    func apply(_ list: [MetadataScraper.AlbumCandidate]) -> [MetadataScraper.AlbumCandidate] {
        switch self {
        case .album, .title:
            list.sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
        case .artist:
            list.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .year, .duration:
            list.sorted { ($0.year ?? "") > ($1.year ?? "") }   // newest first, undated last
        case .relevance: list
        }
    }

    func apply(_ list: [LRCLibClient.Candidate]) -> [LRCLibClient.Candidate] {
        switch self {
        case .title, .album:
            list.sorted { $0.track.localizedStandardCompare($1.track) == .orderedAscending }
        case .artist:
            list.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .duration, .year:
            list.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        case .relevance: list
        }
    }
}

/// The finder sheets' search bar: pinned to the BOTTOM (#6f), free-text that pivots on an artist
/// name (#6d), with sort and filter controls (#6e). Shared by Find Metadata, Find Artwork and the
/// player's lyrics finder so all three behave identically.
struct FinderSearchBar: View {
    @Binding var query: String
    @Binding var sort: FinderSort
    @Binding var matchingOnly: Bool
    /// What the filter toggle means differs per surface — track count on the album finders,
    /// synced-only on the lyrics finder — so the label travels with it.
    var filterLabel = "Only my track count"
    var sortOptions: [FinderSort] = FinderSort.albumOptions
    var placeholder = "Search MusicBrainz"
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(sortOptions) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Toggle(filterLabel, isOn: $matchingOnly)
            } label: {
                Image(systemName: matchingOnly
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.body)
            }
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit(onSearch)
            Button(action: onSearch) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

/// "Find better metadata" for one album: lists MusicBrainz release candidates so the user picks
/// the right pressing (the auto pass takes the top hit; this is the manual override for wrong or
/// missing matches). Applying pulls that release's tracklist + cover onto the whole folder.
struct AlbumFinderSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let albumName: String
    @State private var candidates: [MetadataScraper.AlbumCandidate] = []
    @State private var loading = true
    @State private var applying: String?
    @State private var query = ""
    @State private var sort: FinderSort = .relevance
    @State private var matchingOnly = false

    /// Sort + filter applied to whatever the last search returned (#6e).
    private var shown: [MetadataScraper.AlbumCandidate] {
        let mine = library.trackCount(forAlbum: albumName)
        return sort.apply(matchingOnly ? candidates.filter { $0.trackCount == mine } : candidates)
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                } else if shown.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "questionmark.circle",
                                           description: Text(candidates.isEmpty
                                               ? "MusicBrainz had nothing for “\(query)”. Edit the search below and try again."
                                               : "Every match was filtered out. Turn off “Only my track count” below."))
                }
                ForEach(shown) { c in
                    Button {
                        applying = c.id
                        Task {
                            await library.applyAlbumCandidate(c, to: albumName)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.album).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(c.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(c.detail).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                    .disabled(applying != nil)
                    .overlay(alignment: .trailing) {
                        if applying == c.id { ProgressView() }
                    }
                }
            }
            .navigationTitle("Find Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                FinderSearchBar(query: $query, sort: $sort, matchingOnly: $matchingOnly,
                                onSearch: runSearch)
            }
        }
        .task {
            query = albumName
            candidates = await library.albumCandidates(for: albumName)
            loading = false
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        Task {
            // Free-text goes through the pivoting search, not the tag-seeded one (#6d).
            candidates = await library.searchAlbums(query: q)
            loading = false
        }
    }
}

/// "Find Artwork" for one album: fetches the cover of each MusicBrainz release candidate and shows
/// them as a grid so the user picks the best one; applying stamps it on every track of the album.
struct AlbumArtworkFinderSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let albumName: String
    /// The candidate is kept alongside its cover so sort and filter can work on real fields
    /// rather than on the images (#6e).
    @State private var covers: [(cand: MetadataScraper.AlbumCandidate, image: UIImage)] = []
    @State private var loading = true
    @State private var applying: String?
    @State private var query = ""
    @State private var sort: FinderSort = .relevance
    @State private var matchingOnly = false

    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    private var shown: [(cand: MetadataScraper.AlbumCandidate, image: UIImage)] {
        let mine = library.trackCount(forAlbum: albumName)
        let kept = matchingOnly ? covers.filter { $0.cand.trackCount == mine } : covers
        let order = sort.apply(kept.map(\.cand)).map(\.id)
        return kept.sorted { a, b in
            (order.firstIndex(of: a.cand.id) ?? 0) < (order.firstIndex(of: b.cand.id) ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(40)
                } else if shown.isEmpty {
                    ContentUnavailableView("No artwork found", systemImage: "photo",
                                           description: Text(covers.isEmpty
                                               ? "MusicBrainz / Cover Art Archive had no covers for “\(query.isEmpty ? albumName : query)”."
                                               : "Every cover was filtered out. Turn off “Only my track count” below."))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(shown, id: \.cand.id) { cover in
                            Button {
                                applying = cover.cand.id
                                Task {
                                    await library.applyAlbumArtwork(cover.image, to: albumName)
                                    dismiss()
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(uiImage: cover.image).resizable().aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay { if applying == cover.cand.id { ProgressView().tint(.white) } }
                                    // With an artist pivot in play the grid can hold covers from
                                    // several releases, so each one has to say which it is.
                                    Text(cover.cand.album).font(.caption2).lineLimit(1)
                                    Text(cover.cand.detail).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(applying != nil)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Find Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                FinderSearchBar(query: $query, sort: $sort, matchingOnly: $matchingOnly,
                                onSearch: runSearch)
            }
        }
        .task {
            query = albumName
            await load(await library.albumCandidates(for: albumName))
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        covers = []
        Task { await load(await library.searchAlbums(query: q)) }
    }

    /// Covers arrive one at a time (one CAA hop each) and are appended as they land, so the grid
    /// fills progressively instead of blocking on the slowest release.
    private func load(_ cands: [MetadataScraper.AlbumCandidate]) async {
        for cand in cands {
            if let img = await MetadataScraper.coverArt(mbid: cand.releaseMBID) {
                covers.append((cand, img))
            }
        }
        loading = false
    }
}
