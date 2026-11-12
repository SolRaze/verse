import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @AppStorage(Pref.showFilePaths) private var showFilePaths = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(Coordinator.self) private var coordinator
    // Fast import access in Library ("Import From"); Settings keeps its own.
    @State private var showingImport = false
    @State private var importKind: SettingsView.ImportKind = .files
    @State private var linkText = ""
    @State private var editing: LibraryItem?
    @State private var infoItem: LibraryItem?
    @State private var moveRequest: MoveRequest?
    @State private var addingLink = false
    @State private var pasteSource: LinkSource?
    @State private var newFolderParent: [String]?     // nil = alert hidden
    @State private var newFolderName = ""
    @State private var renamingFolder: [String]?
    @State private var folderNewName = ""
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var path = NavigationPath()
    /// Layout edit mode (#14), Home's implementation: hold a row to enter, minus badge to remove,
    /// drag the row body to reorder, Done pill to leave. The old modal editor is gone — removing
    /// an item there and adding it back left a row that had lost its own remove action.
    @State private var editingLayout = false
    @State private var showGallery = false
    /// Ordered, enabled-only Library root sections.
    @AppStorage(Pref.librarySections) private var sectionsCSV = Pref.librarySectionsDefault

    /// The link kinds the + menu offers. `host` seeds a hint; `addLink` still routes by URL.
    enum LinkSource: String, Identifiable {
        case youtube = "YouTube", spotify = "Spotify", soundcloud = "SoundCloud"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .youtube: "play.rectangle.fill"
            case .spotify: "circle.grid.cross.fill"
            case .soundcloud: "cloud.fill"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The selection binding and the editMode environment each install a pan gesture, and
            // `navigationDestination` below inherits this chain — so an always-on editMode here
            // leaked into FolderView and ate its first interactive pop no matter what FolderView
            // did locally. Wire both up only once the user actually enters Select.
            Group {
                if editMode == .active {
                    List(selection: $selection) { rootRows }
                        .environment(\.editMode, $editMode)
                } else {
                    List { rootRows }
                }
            }
            // Grouped, same as Home (#13). Was plain + edge-to-edge to match
            // `Reference/music-library.png`; the compression that came with it went too far, and
            // Library reading like the homepage matters more than matching that screenshot.
            .listStyle(.insetGrouped)
            // Apple's default row height (#13). Never pin it: a fixed height forces row-by-row
            // opt-outs through the whole file.
            // No search here — the dock's search pill owns search.
            // Same shape as Home: big label on top.
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: FolderPath.self) { fp in
                FolderView(path: fp.components)
            }
            .navigationDestination(for: RemotePlaylist.self) { pl in
                PlaylistDetailView(playlist: pl)
            }
            .navigationDestination(for: CollectionKind.self) { CollectionPage(kind: $0) }
            .navigationDestination(for: ArtistRef.self) { ArtistPage(artist: $0) }
            .navigationDestination(for: AlbumRef.self) { AlbumPage(album: $0) }
            .navigationDestination(for: LocalPlaylist.self) { LocalPlaylistPage(playlist: $0) }
            // Player-burger deep-links. onAppear covers the tab being built cold for the link
            // (a lazy TabView child misses an onChange that fired before it existed).
            .onChange(of: coordinator.deepLink) { _, _ in consumeDeepLink() }
            .onAppear(perform: consumeDeepLink)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if editMode == .active {
                        Button("Done") { editMode = .inactive; selection = [] }
                    }
                }
                // Layout editing's only visible affordance (#14/#17): hold to enter, this to
                // leave. Glass, matching Home's.
                if editingLayout {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { withAnimation(.snappy) { editingLayout = false } }
                            .buttonStyle(.glass)
                    }
                }
                // One menu, not two: the import (+) and options (burger) menus are folded
                // together under three dots.
                ToolbarItem(placement: .topBarTrailing) {
                    // Grouped so the list stays short.
                    Menu {
                        Menu {
                            Button { importKind = .folder; showingImport = true } label: {
                                Label("Folder", systemImage: "folder.badge.plus")
                            }
                            Button { importKind = .files; showingImport = true } label: {
                                Label("Files", systemImage: "doc.badge.plus")
                            }
                            Divider()
                            ForEach([LinkSource.youtube, .spotify, .soundcloud]) { src in
                                Button { linkText = ""; pasteSource = src } label: {
                                    Label(src.rawValue, systemImage: src.icon)
                                }
                            }
                        } label: { Label("Import From", systemImage: "square.and.arrow.down") }
                        Divider()
                        // #12: Library edit = multi-select for batch ops (per-song editing is a
                        // swipe action). The old duplicate "Edit" song button is gone.
                        Button { editMode = .active } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { newFolderName = ""; newFolderParent = [] } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        SortMenu()
                        Divider()
                        // No "Edit Library" item: the layout is edited in place now, by holding a
                        // row (#14, same rule as Home).
                        NavigationLink { SettingsView(embedded: true) } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        // Bare dots, no circle.
                        Image(systemName: "ellipsis")
                    }
                    // Stable hook for UI tests — SwiftUI labels an ellipsis menu "More", which
                    // isn't a contract.
                    .accessibilityIdentifier("libraryMenu")
                    .disabled(addingLink)
                }
            }
            .overlay { if addingLink { ProgressView().controlSize(.large) } }
            // The mini player lives on the tab shell (RootView), not here — it has to survive
            // navigation and tab switches. Only the edit-mode bar is this screen's business.
            .safeAreaInset(edge: .bottom) {
                if editMode == .active {
                    BatchBar(selection: $selection, editMode: $editMode, moveRequest: $moveRequest)
                }
            }
            .fileImporter(isPresented: $showingImport,
                          allowedContentTypes: importKind.types,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                switch importKind {
                case .folder: library.add(pickedURLs: urls)
                case .files: library.add(pickedFiles: urls)
                }
            }
            .alert("Paste \(pasteSource?.rawValue ?? "") link", isPresented: .init(
                get: { pasteSource != nil },
                set: { if !$0 { pasteSource = nil } })
            ) {
                TextField("URL", text: $linkText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add") { addLink() }
                Button("Cancel", role: .cancel) { linkText = "" }
            }
            .alert("New Folder", isPresented: .init(
                get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })
            ) {
                TextField("Name", text: $newFolderName)
                Button("Create") {
                    library.createFolder(named: newFolderName, in: newFolderParent ?? [])
                    newFolderName = ""; newFolderParent = nil
                }
                Button("Cancel", role: .cancel) { newFolderName = ""; newFolderParent = nil }
            }
            .alert("Rename Folder", isPresented: .init(
                get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
            ) {
                TextField("Name", text: $folderNewName)
                Button("Rename") {
                    if let p = renamingFolder { library.renameFolder(p, to: folderNewName) }
                    renamingFolder = nil
                }
                Button("Cancel", role: .cancel) { renamingFolder = nil }
            }
            // The player sheet is app-level (RootView) — a play started from the Home tab has to
            // present it too.
            .sheet(item: $editing) { item in EditItemSheet(item: item) }
            .sheet(item: $infoItem) { item in InfoSheet(item: item) }
            .sheet(item: $moveRequest) { req in MoveSheet(request: req) }
            .sheet(isPresented: $showGallery) {
                LayoutGallerySheet(title: "Add to Library", entries: LibraryLayout.catalog,
                                   placed: Set(sectionIDs)) { addSection($0); showGallery = false }
            }
        }
        .preferredColorScheme(.dark)  // tint inherits from RootView (theme-aware)
    }

    // MARK: sections

    /// The root, in the order the layout pref stores. Collection rows are emitted bare, which is
    /// what lets a collection row sit anywhere in the order; under `.listStyle(.insetGrouped)`
    /// adjacent loose rows collect into one card, so they read as a group without being a
    /// `Section` that would pin them together.
    @ViewBuilder private var rootRows: some View {
        ForEach(sectionIDs, id: \.self) { id in
            switch id {
            case "folders": folderContents(path: [])      // top-level folders + loose items
            case "recentAdded": recentlyAddedSection
            default:
                if let kind = CollectionKind.allCases.first(where: { $0.id == id }) {
                    collectionRow(kind)
                }
            }
        }
        if editingLayout { addLayoutRow }
    }

    private var sectionIDs: [String] { LibraryLayout.parse(sectionsCSV) }

    // MARK: layout editing (#14)

    /// Hold any root row to enter. No button opens it — same rule Home follows (#17), and the •••
    /// menu's "Edit Library" item went with the modal editor it opened.
    private func enterLayoutEdit() {
        guard !editingLayout, editMode != .active else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.snappy) { editingLayout = true }
    }

    private func removeSection(_ id: String) {
        sectionsCSV = LibraryLayout.csv(sectionIDs.filter { $0 != id })
    }

    private func addSection(_ id: String) {
        sectionsCSV = LibraryLayout.csv(sectionIDs + [id])
    }

    private func moveSection(_ dragged: String, before target: String) {
        sectionsCSV = LibraryLayout.csv(HomeLayout.move(sectionIDs, dragged, before: target))
    }

    /// Wraps a root row in the edit affordances: minus badge in front of it, body draggable.
    @ViewBuilder private func layoutEditable<V: View>(_ id: String,
                                                      @ViewBuilder _ row: () -> V) -> some View {
        HStack(spacing: 10) {
            if editingLayout { LayoutMinusBadge { removeSection(id) } }
            row()
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) { enterLayoutEdit() }
        .modifier(ReorderDrag(id: id, active: editingLayout) { moveSection($0, before: id) })
    }

    /// Control Center's "Add a Control", as a list row: only there while editing.
    private var addLayoutRow: some View {
        Button { showGallery = true } label: {
            Label("Add to Library", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    /// Recently Added, expanded inline — the tracks most recently imported, with the shared hold
    /// menu (#10 — Added, not Played).
    ///
    /// Body is 1:1 with `HomeView.recentlyAddedSection` (#13), down to the 6-row cap: the two
    /// surfaces must show the same shelf the same way. No row-height or inset opt-outs here —
    /// they only exist to fight a pinned row height, and there is none.
    @ViewBuilder private var recentlyAddedSection: some View {
        let recent = library.items
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
            .prefix(6).map { $0 }
        if !recent.isEmpty {
            Section {
                ForEach(recent) { item in
                    Button { coordinator.play(item, in: recent) } label: { ItemRow(item: item) }
                        .tint(.primary)
                        .contextMenu { ItemContextMenu(item: item, queue: recent, infoItem: $infoItem) }
                }
            } header: {
                layoutEditable("recentAdded") { Text("Recently Added") }
            }
        }
    }

    /// Apple-Music-style entry rows: Playlists / Artists / Albums / Songs / Favourites. Remote
    /// playlists moved off the root into the Playlists page.
    /// Default spacing (#13) — the hand-set insets went with the compression. Fixed icon column
    /// stays, so the labels still line up.
    ///
    /// These five sit on the page background, not on the grouped card: in
    /// `Reference/music-app/music-library.png` they are bare rows on black, separators only. The
    /// rest of the root keeps its cards — the card under these five is the part that reads wrong.
    private func collectionRow(_ kind: CollectionKind) -> some View {
        layoutEditable(kind.id) {
            NavigationLink(value: kind) {
                Label {
                    Text(kind.rawValue).font(.body)
                } icon: {
                    Image(systemName: kind.icon)
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                }
            }
            // A live link inside edit mode would navigate away mid-drag.
            .disabled(editingLayout)
        }
        .listRowBackground(Color.clear)
    }

    /// Replace the stack with the deep-linked destination. `folder([])` = a loose root track:
    /// popping to the root is the whole navigation.
    private func consumeDeepLink() {
        guard let link = coordinator.deepLink else { return }
        coordinator.deepLink = nil
        path = NavigationPath()
        switch link {
        case .folder(let components):
            if !components.isEmpty { path.append(FolderPath(components)) }
        case .artist(let name):
            path.append(ArtistRef(name: name))
        case .album(let name):
            path.append(AlbumRef(name: name))
        }
    }

    /// User-created folders + loose items at `path`. Imported source trees are NOT listed —
    /// metadata (the collections above) organizes the library — unless Settings › Library ›
    /// Show File Locations turns the disk tree back on.
    @ViewBuilder private func folderContents(path: [String]) -> some View {
        let child = library.children(of: path)
        let folders = showFilePaths
            ? child.folders : library.visibleFolders(at: path)
        if !folders.isEmpty || !child.items.isEmpty {
            Section {
                ForEach(folders, id: \.self) { name in
                    NavigationLink(value: FolderPath(path + [name])) {
                        FolderRow(name: name, count: library.descendants(of: path + [name]).count)
                    }
                    // Default insets (#13) — folder contents sit on the same spacing as
                    // everything else now, not the 1pt squeeze.
                    .swipeActions {
                        Button(role: .destructive) { library.removeFolder(path + [name]) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu { folderMenu(path + [name]) }
                }
                ForEach(child.items) { item in
                    itemButton(item, queue: child.items)
                }
            }
        }
    }

    private func itemButton(_ item: LibraryItem, queue: [LibraryItem]) -> some View {
        Button {
            coordinator.play(item, in: queue)
        } label: {
            ItemRow(item: item)
        }
        .tag(item.id)
        .tint(.primary)
        .swipeActions {
            Button(role: .destructive) { library.remove(item) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { editing = item } label: { Label("Edit", systemImage: "pencil") }
        }
        .contextMenu { itemMenu(item, queue: queue) }
    }

    @ViewBuilder private func folderMenu(_ path: [String]) -> some View {
        FolderContextMenu(path: path, renamingFolder: $renamingFolder,
                          folderNewName: $folderNewName, newFolderParent: $newFolderParent,
                          moveRequest: $moveRequest)
    }

    @ViewBuilder private func itemMenu(_ item: LibraryItem, queue: [LibraryItem]) -> some View {
        ItemContextMenu(item: item, queue: queue, infoItem: $infoItem)
    }

    private func addLink() {
        guard let url = URL(string: linkText.trimmingCharacters(in: .whitespaces)),
              url.host != nil else { return }
        linkText = ""
        addingLink = true
        Task {
            defer { addingLink = false }
            do {
                try await playlists.add(url: url)
            } catch PlaylistFetcher.FetchError.unsupportedURL where url.host?.contains("yout") == true {
                library.add(youtubeURL: url)   // plain video link
            } catch {
                coordinator.lastError = error.localizedDescription
            }
        }
    }
}

/// Navigable folder path. A plain `[String]` can't be a `navigationDestination` value type without
/// clashing with other array destinations, so wrap it.
struct FolderPath: Hashable {
    let components: [String]
    init(_ components: [String]) { self.components = components }
}

// MARK: - Folder screen (recursive)

struct FolderView: View {
    @AppStorage(Pref.showFilePaths) private var showFilePaths = false
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    @State private var editing: LibraryItem?
    @State private var infoItem: LibraryItem?
    @State private var moveRequest: MoveRequest?
    @State private var newFolderParent: [String]?
    @State private var newFolderName = ""
    @State private var renamingFolder: [String]?
    @State private var folderNewName = ""
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    let path: [String]

    @ViewBuilder private func rows(_ child: (folders: [String], items: [LibraryItem])) -> some View {
        // `child.folders` here is pre-filtered to user-created folders by the caller.
        ForEach(child.folders, id: \.self) { name in
            NavigationLink(value: FolderPath(path + [name])) {
                FolderRow(name: name, count: library.descendants(of: path + [name]).count)
            }
            .swipeActions {
                Button(role: .destructive) { library.removeFolder(path + [name]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                FolderContextMenu(path: path + [name], renamingFolder: $renamingFolder,
                                  folderNewName: $folderNewName, newFolderParent: $newFolderParent,
                                  moveRequest: $moveRequest)
            }
        }
        ForEach(child.items) { item in
            Button { coordinator.play(item, in: child.items) } label: { ItemRow(item: item) }
                .tag(item.id)
                .tint(.primary)
                .swipeActions {
                    Button(role: .destructive) { library.remove(item) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { editing = item } label: { Label("Edit", systemImage: "pencil") }
                }
                .contextMenu {
                    ItemContextMenu(item: item, queue: child.items, infoItem: $infoItem)
                }
        }
    }

    var body: some View {
        // User-created subfolders only, unless Show File Locations is on (Settings › Library).
        let all = library.children(of: path)
        let child = (folders: showFilePaths
                        ? all.folders : library.visibleFolders(at: path),
                     items: all.items)
        // Plain List with NO editMode environment while browsing — both a selection binding and
        // an editMode binding install pan gestures that fight the interactive swipe-back
        // (it took two swipes). Only wire them up once the user actually enters Select.
        Group {
            if editMode == .active {
                List(selection: $selection) { rows(child) }
                    .environment(\.editMode, $editMode)
            } else {
                List { rows(child) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(path.last ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editMode == .active {
                    Button("Done") { editMode = .inactive; selection = [] }
                } else {
                    Menu {
                        Button {
                            let all = library.descendants(of: path)
                            if let first = all.first { coordinator.play(first, in: all) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        Button { editMode = .active } label: { Label("Select", systemImage: "checkmark.circle") }
                        Button { newFolderName = ""; newFolderParent = path } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        SortMenu()
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .alert("New Folder", isPresented: .init(
            get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })
        ) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                library.createFolder(named: newFolderName, in: newFolderParent ?? path)
                newFolderName = ""; newFolderParent = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = ""; newFolderParent = nil }
        }
        .alert("Rename Folder", isPresented: .init(
            get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
        ) {
            TextField("Name", text: $folderNewName)
            Button("Rename") {
                if let p = renamingFolder { library.renameFolder(p, to: folderNewName) }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                BatchBar(selection: $selection, editMode: $editMode, moveRequest: $moveRequest)
            }
        }
        .sheet(item: $editing) { item in EditItemSheet(item: item) }
        .sheet(item: $infoItem) { item in InfoSheet(item: item) }
        .sheet(item: $moveRequest) { req in MoveSheet(request: req) }
    }
}

// MARK: - Rows

/// "1 item" / "12 items".
func itemCountText(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s")" }

struct FolderRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.subheadline).foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.subheadline).lineLimit(1)
                Text(itemCountText(count)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ItemRow: View {
    // Observe the store so rows re-render when background artwork extraction finishes.
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let item: LibraryItem

    private var isNowPlaying: Bool { coordinator.nowPlayingItemID == item.id }

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.subheadline).lineLimit(1)
                    .foregroundStyle(isNowPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if !item.artist.isEmpty {
                    Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isNowPlaying {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.player.isPlaying)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        let _ = library.artworkVersion   // re-render trigger
        // 28pt row — `thumb`, not `image`. This is the most-rendered row in the app.
        if let local = Artwork.thumb(for: item.id.uuidString) {
            Image(uiImage: local).resizable().scaledToFill()
        } else if let remote = item.thumbnailURL {
            AsyncImage(url: remote) { $0.resizable().scaledToFill() } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            .overlay(Image(systemName: item.isVideo ? "film" : "music.note")
                .foregroundStyle(.secondary))
    }
}

struct PlaylistRow: View {
    let playlist: RemotePlaylist

    private var icon: String {
        switch playlist.kind {
        case .youtubePlaylist, .youtubeChannel: "play.rectangle.fill"
        case .spotify: "circle.grid.cross.fill"
        case .soundcloud: "cloud.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text(itemCountText(playlist.entries.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Remote playlist detail

struct PlaylistDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(Coordinator.self) private var coordinator
    @State private var refreshing = false
    let playlist: RemotePlaylist

    private var current: RemotePlaylist {
        playlists.playlists.first { $0.id == playlist.id } ?? playlist
    }

    var body: some View {
        List {
            ForEach(Array(current.entries.enumerated()), id: \.offset) { i, entry in
                Button {
                    coordinator.play(current, at: i)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing).monospacedDigit()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline).lineLimit(1)
                            if !entry.artist.isEmpty {
                                Text(entry.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if PlaylistMatcher.match(entry, in: library.items) != nil {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if refreshing {
                    ProgressView()
                } else {
                    Button {
                        refreshing = true
                        Task {
                            defer { refreshing = false }
                            do { try await playlists.refresh(current) }
                            catch { coordinator.lastError = error.localizedDescription }
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

// MARK: - Mini player

/// Apple Music's pill: art left, title middle, play + forward right. Always present (idle =
/// "Not Playing") so the dock never changes shape when playback starts.
struct MiniPlayerBar: View {
    @Environment(Coordinator.self) private var coordinator
    let player: Player

    private var idle: Bool { coordinator.nowTitle.isEmpty }

    private var playing: Bool {
        coordinator.engine == .vlc ? player.isPlaying : coordinator.airPlayer.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(idle ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(idle ? "Not Playing" : coordinator.nowTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(idle ? .secondary : .primary)
                    .lineLimit(1)
                if !idle, !coordinator.nowArtist.isEmpty {
                    Text(coordinator.nowArtist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            Button {
                if coordinator.engine == .vlc {
                    player.toggle()
                } else {
                    playing ? coordinator.airPlayer.player.pause() : coordinator.airPlayer.player.play()
                }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3)
            }
            .disabled(idle)
            Button { coordinator.skip(1) } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .disabled(idle)
        }
        .opacity(idle ? 0.7 : 1)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        // No background: the tab bar's bottom accessory is already a glass capsule, so drawing
        // another material capsule in here nests one inside the other.
        .contentShape(Capsule())
        .onTapGesture { if !idle { coordinator.showPlayer = true } }
    }

    @ViewBuilder private var artwork: some View {
        if let art = coordinator.player.current?.artwork {
            Image(uiImage: art).resizable().scaledToFill()
        } else if let thumb = coordinator.nowPlayingItem?.thumbnailURL {
            AsyncImage(url: thumb) { $0.resizable().scaledToFill() } placeholder: { artPlaceholder }
        } else {
            artPlaceholder
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.white.opacity(0.1))
            .overlay(Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary))
    }
}


// MARK: -

/// Shared context menu for a track, identical everywhere: playlists and lyrics.
struct ItemContextMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let item: LibraryItem
    let queue: [LibraryItem]
    @Binding var infoItem: LibraryItem?

    var body: some View {
        Button { coordinator.play(item, in: queue) } label: { Label("Play", systemImage: "play.fill") }
        Menu {
            Button { coordinator.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { coordinator.playLast(item) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        Menu {
            ForEach(library.localPlaylists) { pl in
                Button(pl.name) { library.add(item, to: pl) }
            }
            if !library.localPlaylists.isEmpty { Divider() }
            Button { library.newPlaylist(with: item) } label: {
                Label("New Playlist", systemImage: "plus")
            }
        } label: { Label("Add to Playlist", systemImage: "music.note.list") }
        if case .file = item.source {
            Button { Task { await library.fetchLyrics(item) } } label: {
                Label("Fetch Lyrics", systemImage: "quote.bubble")
            }
        }
        Button { infoItem = item } label: { Label("Info", systemImage: "info.circle") }
        if let urls = library.shareItems(item) {
            ShareLink(items: urls) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { library.remove(item) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Shared context menu for a folder.
struct FolderContextMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    let path: [String]
    @Binding var renamingFolder: [String]?
    @Binding var folderNewName: String
    @Binding var newFolderParent: [String]?
    @Binding var moveRequest: MoveRequest?

    var body: some View {
        Button {
            let all = library.descendants(of: path)
            if let f = all.first { coordinator.play(f, in: all) }
        } label: { Label("Play", systemImage: "play.fill") }
        Button { newFolderParent = path } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button { folderNewName = path.last ?? ""; renamingFolder = path } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            moveRequest = MoveRequest(title: "Move \(path.last ?? "")", excluding: path) {
                library.moveFolder(path, under: $0)
            }
        } label: { Label("Move to…", systemImage: "folder") }
        Button(role: .destructive) { library.removeFolder(path) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Sort field + order picker, shared by every browsing screen.
struct SortMenu: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        // @Observable gives no projected value, so the two-way bindings need @Bindable.
        @Bindable var library = library
        Menu {
            Picker("Sort By", selection: $library.sortField) {
                ForEach(SortField.allCases) { f in Label(f.rawValue, systemImage: f.icon).tag(f) }
            }
            Divider()
            Picker("Order", selection: $library.sortAscending) {
                Label("Ascending", systemImage: "arrow.up").tag(true)
                Label("Descending", systemImage: "arrow.down").tag(false)
            }
        } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
    }
}

/// Bottom bar shown in select mode: batch delete / move.
struct BatchBar: View {
    @Environment(LibraryStore.self) private var library
    @Binding var selection: Set<UUID>
    @Binding var editMode: EditMode
    @Binding var moveRequest: MoveRequest?

    var body: some View {
        HStack {
            Button(role: .destructive) {
                library.remove(selection); selection = []; editMode = .inactive
            } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Spacer()
            Text(selection.isEmpty ? "Select Items" : "\(selection.count) selected")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button {
                let ids = selection
                moveRequest = MoveRequest(title: "Move \(ids.count)", excluding: []) { path in
                    library.move(ids, to: path); selection = []; editMode = .inactive
                }
            } label: { Label("Move", systemImage: "folder") }
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}

/// A pending "move to a folder" action — the picker calls `onPick` with the chosen path.
struct MoveRequest: Identifiable {
    let id = UUID()
    let title: String
    let excluding: [String]        // hide this folder subtree (can't move into itself)
    let onPick: ([String]) -> Void
}

/// Pick a destination folder, or make a new one on the spot. Works for a single item, a batch,
/// or a folder — the caller supplies what to do with the picked path.
struct MoveSheet: View {      // shared with the collection pages' hold menus
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    let request: MoveRequest

    private var destinations: [[String]] {
        library.allFolders().filter { !$0.starts(with: request.excluding) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New folder name", text: $newFolderName)
                        Button("Create") {
                            let name = newFolderName.trimmingCharacters(in: .whitespaces)
                            library.createFolder(named: name, in: [])
                            pick([name])
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Move to") {
                    Button { pick([]) } label: { Label("Library (root)", systemImage: "house") }
                    ForEach(destinations, id: \.self) { path in
                        Button { pick(path) } label: {
                            Label(path.joined(separator: " / "), systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .themedTint()
    }

    private func pick(_ path: [String]) { request.onPick(path); dismiss() }
}

/// File-manager "Get Info" panel, editable in place (#11). Edit swaps the value rows for fields
/// on this page instead of raising a second editor sheet on top of it — one metadata screen, not
/// two. Cover and lyric kind sit up top because "which track is this" is what the page is for.
/// `EditItemSheet` stays for the hold menus, which go straight to editing without passing here.
struct InfoSheet: View {      // shared with the player's burger menu
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var info: LibraryStore.FileInfo?
    @State private var editing = false
    /// The in-flight edit, nil outside edit mode so the rows always read the live store value.
    @State private var draft: LibraryItem?
    /// What the fields held when Edit was tapped, so Save freezes only what actually changed.
    @State private var original: LibraryItem?
    /// Track/disc are Ints on the model but text in the fields — an empty field has to mean
    /// "no number", which a numeric binding can't express.
    @State private var trackText = ""
    @State private var discText = ""
    let item: LibraryItem

    /// Read the store, not the captured value — an edit made here has to show up without
    /// reopening the sheet (#6h).
    private var live: LibraryItem { library.items.first { $0.id == item.id } ?? item }

    var body: some View {
        NavigationStack {
            List {
                Section { cover }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if editing {
                    Section {
                        editRow("Title", text: text(\.title))
                        editRow("Artist", text: text(\.artist))
                        editRow("Album", text: text(\.album))
                        editRow("Track", text: $trackText, numeric: true)
                        editRow("Disc", text: $discText, numeric: true)
                    } footer: {
                        Text("Leave a field blank to clear it. A field you edit here stops being "
                             + "overwritten by online metadata.")
                    }
                    if let draft, !draft.frozenFields.isEmpty {
                        Section("Kept from online metadata") {
                            ForEach(MetaField.allCases.filter { draft.frozenFields.contains($0.rawValue) }) { f in
                                HStack {
                                    Text(f.label)
                                    Spacer()
                                    Button("Unlock") { self.draft?.frozenFields.remove(f.rawValue) }
                                        .buttonStyle(.borderless).font(.caption)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        LabeledContent("Title", value: live.title)
                        if !live.artist.isEmpty { LabeledContent("Artist", value: live.artist) }
                        if !live.album.isEmpty { LabeledContent("Album", value: live.album) }
                        if let t = live.trackNumber { LabeledContent("Track", value: String(t)) }
                        if let d = live.discNumber { LabeledContent("Disc", value: String(d)) }
                        LabeledContent("Lyrics", value: lyricsKind)
                    }
                }

                Section {
                    if let info {
                        LabeledContent("Where", value: info.folder)
                        LabeledContent("Name", value: info.location)
                        LabeledContent("Kind", value: info.kind)
                        if let s = info.size {
                            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                        }
                        if let d = info.duration {
                            LabeledContent("Duration", value: durationString(d))
                        }
                        if let a = info.added {
                            LabeledContent("Added", value: a.formatted(date: .abbreviated, time: .shortened))
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { editing ? save() : dismiss() }.buttonStyle(.glass)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "Cancel" : "Edit") {
                        editing ? cancel() : beginEdit()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .themedTint()
        .task { info = await library.info(for: item) }
    }

    @ViewBuilder private var cover: some View {
        let _ = library.artworkVersion   // re-render trigger
        HStack {
            Spacer()
            Group {
                if let local = Artwork.image(for: live.id.uuidString) {
                    Image(uiImage: local).resizable().scaledToFill()
                } else if let remote = live.thumbnailURL {
                    AsyncImage(url: remote) { $0.resizable().scaledToFill() } placeholder: { coverPlaceholder }
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            .overlay(Image(systemName: live.isVideo ? "film" : "music.note")
                .font(.largeTitle).foregroundStyle(.secondary))
    }

    /// Synced / Plain / None / Not fetched — cache-only, so asking on every render is free.
    private var lyricsKind: String {
        LyricsResolver.cachedKind(for: live.id.uuidString).rawValue
    }

    /// Grey field on a grey well, so an editable row reads as editable at a glance (#11).
    private func editRow(_ label: String, text: Binding<String>, numeric: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .keyboardType(numeric ? .numberPad : .default)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func text(_ key: WritableKeyPath<LibraryItem, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" },
                set: { draft?[keyPath: key] = $0 })
    }

    private func beginEdit() {
        let current = live
        trackText = current.trackNumber.map(String.init) ?? ""
        discText = current.discNumber.map(String.init) ?? ""
        draft = current
        original = current
        editing = true
    }

    private func cancel() {
        draft = nil
        original = nil
        editing = false
    }

    private func save() {
        guard var edited = draft, let was = original else { return cancel() }
        edited.trackNumber = Int(trackText.trimmingCharacters(in: .whitespaces))
        edited.discNumber = Int(discText.trimmingCharacters(in: .whitespaces))
        edited.freezeEdits(from: was)
        library.update(edited)
        cancel()
    }

    private func durationString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60)
                         : String(format: "%d:%02d", s/60, s%60)
    }
}

struct EditItemSheet: View {  // shared with the collection pages' hold menus
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State var item: LibraryItem

    /// Track/disc are Ints on the model but text in the form — an empty field has to mean "no
    /// number", which a numeric binding can't express.
    @State private var trackText = ""
    @State private var discText = ""
    /// What the fields held on open, so Save can tell which ones the user actually touched and
    /// freeze only those (#6c).
    @State private var original: LibraryItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $item.title)
                    TextField("Artist", text: $item.artist)
                    TextField("Album", text: $item.album)
                }
                Section {
                    TextField("Track number", text: $trackText).keyboardType(.numberPad)
                    TextField("Disc number", text: $discText).keyboardType(.numberPad)
                } footer: {
                    Text("Leave a field blank to clear it. A field you edit here stops being "
                         + "overwritten by online metadata.")
                }
                if !item.frozenFields.isEmpty {
                    Section("Kept from online metadata") {
                        ForEach(MetaField.allCases.filter { item.frozenFields.contains($0.rawValue) }) { f in
                            HStack {
                                Text(f.label)
                                Spacer()
                                Button("Unlock") { item.frozenFields.remove(f.rawValue) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .themedTint()
        .onAppear {
            trackText = item.trackNumber.map(String.init) ?? ""
            discText = item.discNumber.map(String.init) ?? ""
            original = item
        }
    }

    private func save() {
        item.trackNumber = Int(trackText.trimmingCharacters(in: .whitespaces))
        item.discNumber = Int(discText.trimmingCharacters(in: .whitespaces))
        if let was = original { item.freezeEdits(from: was) }  // #6c, shared with the Info page
        library.update(item)
        dismiss()
    }
}
