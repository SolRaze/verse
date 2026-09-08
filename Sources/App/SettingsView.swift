import SwiftUI
import UniformTypeIdentifiers

/// Preference keys, shared between the Settings UI (@AppStorage) and the core classes that read
/// them straight from UserDefaults (NowPlaying, Player). One module, so both sides reference
/// these constants — no string drift.
enum Pref {
    static let theme = "appearance.theme"
    static let carPlayTextFallback = "lyrics.carPlayTextFallback"
    static let lyricsCoverColour = "lyrics.coverColour"
    static let sponsorBlock = "playback.sponsorBlock"
    static let showFilePaths = "library.showFilePaths"
    static let tintedBackground = "appearance.tintedBackground"  // player bg from cover colour
    static let iPodMode = "appearance.iPodMode"                  // click-wheel skeleton (beta)
    static let createUnlocked = "create.unlocked"               // hidden Create page revealed
    static let createTiles = "create.tiles"                     // JSON [CreateTile]
    static let ipodWheelColour = "ipod.wheelColour"             // RRGGBB, "" = classic grey
    static let ipodScreenColour = "ipod.screenColour"           // RRGGBB, "" = classic green LCD
    static let lyricsFont = "lyrics.fontDesign"      // design keyword or PostScript name
    static let lyricsSize = "lyrics.fontSize"        // Double, points; 22 = old title2 look
    static let customSwatches = "appearance.customSwatches"  // comma-joined RRGGBB list
    static let likeGlyph = "player.likeGlyph"                // SF Symbol base for the favourite button
    static let likeGlyphSlots = "player.likeGlyphSlots"      // the 6 strip slots, comma-joined
    static let likeGlyphRecents = "player.likeGlyphRecents"  // browser's Recently Used, newest first

    /// The whole browsable icon library (#18) — the strip itself is six of these, chosen in the
    /// browser and stored in `likeGlyphSlots`. Every one has a `.fill` variant for the liked
    /// state — the strip and the button both draw `<glyph>.fill` when lit, so a fill-less symbol
    /// would break. `ReactionTests` fails if any entry or its `.fill` stops resolving.
    static let likeGlyphs = [
        "heart", "star", "bolt", "flame", "crown", "face.smiling",
        "hand.thumbsup", "hand.thumbsdown", "moon", "sun.max", "drop", "leaf",
        "diamond", "circle", "square", "triangle", "hexagon", "seal",
        "shield", "bookmark", "tag", "bell", "cloud", "eye",
        "pin", "flag", "key", "lock", "gift", "cart",
        "bag", "envelope", "paperplane", "camera", "mic", "play",
        "pause", "stop", "speaker.wave.2", "guitars", "theatermasks", "gamecontroller",
        "puzzlepiece", "paintbrush", "paintpalette", "hammer", "gearshape", "lightbulb",
        "book", "graduationcap", "house", "car", "trophy", "pawprint",
        "tortoise", "hare", "ant", "ladybug", "fish", "bird",
        "globe.americas", "smoke",
    ]

    // Home shelves: ordered, enabled-only ids (hold a shelf header to move/remove; the
    // ellipsis menu adds). Replaces the old per-shelf bools.
    static let homeSections = "home.sections"       // shelf zone: ordered shelf ids
    static let homeTiles = "home.tiles"             // tile zone: "id:cols:rows", ordered

    /// Collection view prefs, remembered per collection (#16) — suffix is the `CollectionKind`
    /// id, e.g. "collection.columns.albums". Columns is 2 or 3 and only means anything for the
    /// grid kinds; songs and favourites stay lists. Grouping is a `CollectionPage.Grouping` raw
    /// value.
    static func collectionColumns(_ kind: String) -> String { "collection.columns.\(kind)" }
    static func collectionGrouping(_ kind: String) -> String { "collection.grouping.\(kind)" }

    /// Library root layout: ordered, enabled-only ids, edited from Library › ••• › Edit Library.
    /// Ids are the `CollectionKind` ids plus "folders" and "recentAdded" (the Library
    /// menu's Edit is the LIBRARY's layout, not Home's).
    static let librarySections = "library.sections"
    static let librarySectionsDefault = "playlists,artists,albums,songs,favourites,folders,recentAdded"

    /// Lyrics fonts, every one with a real name and previewable. `id` is a system design
    /// keyword or a PostScript name (iOS built-ins — nothing bundled).
    static let lyricFonts: [(id: String, name: String)] = [
        ("system", "San Francisco"), ("rounded", "SF Rounded"), ("serif", "New York"),
        ("mono", "SF Mono"), ("Charter-Roman", "Charter"), ("Georgia", "Georgia"),
        ("AvenirNext-Medium", "Avenir Next"), ("Palatino-Roman", "Palatino"),
        ("Baskerville", "Baskerville"), ("Futura-Medium", "Futura"),
        ("Menlo-Regular", "Menlo"), ("TimesNewRomanPS-BoldMT", "Times New Roman"),
    ]

    static func lyricsFont(id: String, size: Double) -> Font {
        switch id {
        case "system": .system(size: size, weight: .bold)
        case "rounded": .system(size: size, weight: .bold, design: .rounded)
        case "serif": .system(size: size, weight: .bold, design: .serif)
        case "mono": .system(size: size, weight: .bold, design: .monospaced)
        default: .custom(id, size: size)
        }
    }
    static let onlineMetadata = "metadata.online"
    /// #6b: skip re-searching anything already found (tags, artwork, lyrics). ON by default —
    /// re-querying what you already have is the slow, rate-limited half of a fetch run.
    static let skipAlreadyFound = "metadata.skipFound"
    static let metadataExcludedFolders = "metadata.excludedFolders"  // newline-joined root names

    /// Accent swatches offered before the custom picker ("a group like the icon
    /// selection, and the colour of the square"). "" = stock white; Red = the Yeezus/Classic
    /// tape, Violet = the exact Yandhi tape square. The rest are pastels.
    static let accentPresets: [(hex: String, name: String)] = [
        ("", "White"), ("F0241C", "Red"), ("97479E", "Violet"),
        ("AEC6CF", "Blue"), ("77DD77", "Green"), ("FFB347", "Orange"), ("FFB6C1", "Pink"),
    ]

    /// Defaults that aren't false/empty. Call once at launch before anything reads them.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sponsorBlock: true, lyricsSize: 22.0,
            homeSections: "now,playlists,albums,tracks",
            librarySections: librarySectionsDefault,
            skipAlreadyFound: true,
            likeGlyph: "heart",
        ])
    }

    /// Accent stored as RRGGBB hex; anything unparseable (including the empty default) means
    /// stock white. Full colour range, the one user-picked exception to the no-colored-chrome
    /// rule, and it is sanctioned only through this Settings page.
    static func color(for stored: String) -> Color {
        guard stored.count == 6, let v = UInt32(stored, radix: 16) else { return .white }
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    static func hex(of color: Color) -> String {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

extension View {
    /// Sheets don't inherit the shell's tint — restate the user's accent on presentation.
    /// ponytail: reads defaults once at render; a theme change mid-sheet lags until reopen.
    func themedTint() -> some View {
        tint(Pref.color(for: UserDefaults.standard.string(forKey: Pref.theme) ?? "White"))
    }
}

/// The personalization hub: every user-tweakable knob lives here, grouped by surface.
struct SettingsView: View {
    @AppStorage(Pref.theme) private var theme = ""
    @AppStorage(Pref.carPlayTextFallback) private var carPlayFallback = false
    @AppStorage(Pref.lyricsCoverColour) private var lyricsCoverColour = false
    @AppStorage(Pref.sponsorBlock) private var sponsorBlock = true
    @AppStorage(Pref.lyricsFont) private var lyricsFont = "system"
    @AppStorage(Pref.lyricsSize) private var lyricsSize = 22.0
    @AppStorage(Pref.customSwatches) private var customSwatches = ""
    @AppStorage(Pref.tintedBackground) private var tintedBackground = false
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    @State private var cachesCleared = false
    @State private var wipAlert: String?

    /// Planned features (mirrors my planned list) — shown faded under "In the Works", grouped by the
    /// surface they'll land on so the list reads by where it'll appear.
    /// (iPod Mode graduated to a beta toggle in Appearance.)
    static let inTheWorks: [(area: String, items: [String])] = [
        ("Player", ["Stem Player (per-stem audio)", "Karaoke Word Timing"]),
        ("Library", ["Jellyfin Servers", "Locations Tab", "Hi-Res / Low-Res Version Picker",
                     "Folder Organize Macro"]),
        ("Home", ["Wrapped (year recap)"]),
        ("Import", ["Import Summary Sheet"]),
    ]
    // Owned by the system, not UserDefaults — read back what's actually set.
    @State private var appIcon: String? = UIApplication.shared.alternateIconName

    // Settings is the one place that opens folders and files.
    enum ImportKind {
        case folder, files
        var types: [UTType] {
            switch self {
            case .folder: [.folder]
            case .files: [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav, .aiff]
            }
        }
    }

    /// true = pushed inside Library's stack (top-left gear); false = standalone.
    var embedded = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        // Sheets don't inherit the shell's chrome — restate it, live-tinted by the picker.
        .tint(Pref.color(for: theme))
        .preferredColorScheme(.dark)
    }

    private var content: some View {
            List {
                // Library first — import and maintenance outrank cosmetics.
                Section {
                    // Import lives inside Locations now (its + menu, top right).
                    NavigationLink {
                        LocationsView()
                    } label: {
                        LabeledContent {
                            Text(library.importedRoots.isEmpty ? "None"
                                : "\(library.importedRoots.count)")
                        } label: {
                            Label("Locations", systemImage: "folder")
                        }
                    }
                    NavigationLink {
                        MetadataSettingsView()
                    } label: {
                        Label("Metadata & Fetching", systemImage: "text.magnifyingglass")
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Locations lists every imported folder (swipe to remove — files and their sidecars stay on disk, re-import restores everything). Fetching and online lookup live under Metadata & Fetching.")
                }

                Section {
                    AccentSwatches(theme: $theme, custom: $customSwatches)
                    ColorPicker("Custom Colour", selection: Binding(
                        get: { Pref.color(for: theme) },
                        set: { theme = Pref.hex(of: $0) }
                    ), supportsOpacity: false)
                    // Promote the picked colour into the swatch row for one-tap switching.
                    if !theme.isEmpty,
                       !Pref.accentPresets.contains(where: { $0.hex == theme.uppercased() }),
                       !customSwatches.split(separator: ",").map(String.init).contains(theme.uppercased()) {
                        Button("Save Colour as Preset") {
                            let all = customSwatches.split(separator: ",").map(String.init) + [theme.uppercased()]
                            customSwatches = all.suffix(6).joined(separator: ",")  // cap the row
                        }
                    }
                    NavigationLink {
                        LyricsFontPicker(selection: $lyricsFont)
                    } label: {
                        LabeledContent("Lyrics Font",
                                       value: Pref.lyricFonts.first { $0.id == lyricsFont }?.name ?? "San Francisco")
                    }
                    HStack {
                        Text("Lyrics Size")
                        Slider(value: $lyricsSize, in: 16...34, step: 1)
                        Text("\(Int(lyricsSize))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        IconPickerView(appIcon: $appIcon)
                    } label: {
                        LabeledContent("App Icon",
                                       value: IconPickerView.icons.first { $0.id == appIcon }?.label ?? "Verse")
                    }
                    NavigationLink { IPodSettingsView() } label: {
                        Label("iPod Mode", systemImage: "opticaldisc")
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Tints buttons and controls everywhere — any colour. White is the stock look.")
                }

                Section {
                    Toggle("CarPlay Lyrics", isOn: $carPlayFallback)
                    Toggle("Colour From Cover", isOn: $lyricsCoverColour)
                    Toggle("Tinted Background", isOn: $tintedBackground)
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("CarPlay Lyrics shows the current line in the artist field on CarPlay and the Lock Screen. Colour From Cover tints the active lyric line with the album cover's dominant colour instead of white.")
                }

                Section {
                    Toggle("SponsorBlock", isOn: $sponsorBlock)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("SponsorBlock skips community-flagged sponsor segments in YouTube streams. The sleep timer moved to the player's moon icon.")
                }

                Section {
                    Button(cachesCleared ? "Caches Cleared" : "Clear Caches") { clearCaches() }
                        .disabled(cachesCleared)
                    if let backup = library.backupURL() {
                        ShareLink(item: backup) { Text("Export Library Backup") }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Clear Caches drops cached lyrics, artwork and waveforms — including remembered \"nothing found\" results. Export Library Backup shares one JSON with the whole library, playlists and folders (covers YouTube items, which have no files to carry sidecars).")
                }

                // Faded skeletons for what's planned — tap says so. Same planned list.
                // One section per surface (Player / Library / Home / Import).
                ForEach(Self.inTheWorks, id: \.area) { group in
                    Section {
                        ForEach(group.items, id: \.self) { name in
                            Button { wipAlert = name } label: {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text("planned").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.secondary.opacity(0.6))
                        }
                    } header: {
                        Text("In the Works · \(group.area)")
                    } footer: {
                        if group.area == Self.inTheWorks.last?.area {
                            Text("Planned features from the backlog — not built yet, grouped by where they'll show up.")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert(wipAlert ?? "", isPresented: .init(
                get: { wipAlert != nil }, set: { if !$0 { wipAlert = nil } })
            ) { Button("OK", role: .cancel) {} } message: {
                Text("Work in progress — it's on the backlog.")
            }
    }

    private func clearCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for sub in ["lyrics", "artwork", "waveform"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(sub))
        }
        cachesCleared = true
    }
}

/// Everything about fetching + where metadata lives, moved off the main Settings list into one
/// place: the online toggle, per-folder opt-out, the Fetch buttons,
/// file-path visibility and the sidecar location.
struct MetadataSettingsView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage(Pref.onlineMetadata) private var onlineMetadata = false
    @AppStorage(Pref.skipAlreadyFound) private var skipFound = true
    @AppStorage(Pref.showFilePaths) private var showFilePaths = false
    @AppStorage(Pref.metadataExcludedFolders) private var excludedCSV = ""

    private var excluded: Set<String> {
        Set(excludedCSV.split(separator: "\n").map(String.init))
    }
    private func setExcluded(_ root: String, _ off: Bool) {
        var set = excluded
        if off { set.insert(root) } else { set.remove(root) }
        excludedCSV = set.sorted().joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                Toggle("Online Metadata", isOn: $onlineMetadata)
            } footer: {
                Text("Looks up album, artist and high-res cover art via MusicBrainz on import and rescan. The Fetch buttons below always go online regardless. Off by default — no network unless you ask.")
            }

            Section {
                Toggle("Skip What's Already Found", isOn: $skipFound)
            } footer: {
                Text("Leaves tracks that already have metadata, artwork or lyrics alone instead of searching for them again. They still appear in the fetch review — just marked as found.")
            }

            Section {
                // #6a: where a run's conflicts and gaps get looked at and resolved.
                NavigationLink { FetchReviewView() } label: {
                    Label("Review Results", systemImage: "checklist")
                }
            }

            Section {
                busyButton("Rescan Library") { await library.rescanLibrary() }
                busyButton("Fetch Metadata") { await library.fetchOnlineTags() }
                busyButton("Fetch Artwork") { await library.fetchOnlineArtwork() }
                busyButton("Fetch Lyrics") { await library.fetchAllLyrics() }
                if library.rescanning, !library.rescanStatus.isEmpty {
                    Text(library.rescanStatus)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                } else if !library.lastFetchSummary.isEmpty {
                    Text(library.lastFetchSummary)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Fetch")
            } footer: {
                Text("Albums are looked up whole — one release match brings the tracklist (disc and track numbers) and a single cover for the folder. Lone tracks are searched individually. Covers and albums from MusicBrainz, lyrics from LRCLIB — all saved beside your files.")
            }

            if !library.importedRoots.isEmpty {
                Section {
                    ForEach(library.importedRoots, id: \.self) { root in
                        Toggle(root, isOn: Binding(
                            get: { !excluded.contains(root) },
                            set: { setExcluded(root, !$0) }))
                    }
                } header: {
                    Text("Search These Folders")
                } footer: {
                    Text("Turn a folder off to skip it during online lookups — for bootlegs, mixes or anything MusicBrainz won't have.")
                }
            }

            Section {
                Toggle("Show File Locations", isOn: $showFilePaths)
                NavigationLink {
                    SidecarLocationView()
                } label: {
                    LabeledContent("Metadata Location",
                                   value: library.customSidecarFolderName ?? "Beside files")
                }
            } header: {
                Text("Files")
            }
        }
        .navigationTitle("Metadata")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func busyButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack {
                Text(title)
                if library.rescanning { Spacer(); ProgressView() }
            }
        }
        .disabled(library.rescanning)
    }
}

/// Every imported folder on one page (was a row each in Settings), plus the import actions in a
/// top-right menu. Swipe to remove — files and sidecars stay on disk, so re-importing restores
/// the library.
struct LocationsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showingImport = false
    @State private var importKind: SettingsView.ImportKind = .files

    var body: some View {
        List {
            if library.importedRoots.isEmpty {
                ContentUnavailableView("No folders imported", systemImage: "folder",
                                       description: Text("Add music with the + button, top right."))
            } else {
                ForEach(library.importedRoots, id: \.self) { root in
                    LabeledContent("Folder", value: root)
                        .swipeActions {
                            Button(role: .destructive) {
                                library.removeImportedRoot(root)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                }
            }
        }
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importKind = .folder; showingImport = true } label: {
                        Label("Import Folder", systemImage: "folder.badge.plus")
                    }
                    Button { importKind = .files; showingImport = true } label: {
                        Label("Import Files", systemImage: "doc.badge.plus")
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: importKind.types,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            switch importKind {
            case .folder: library.add(pickedURLs: urls)
            case .files: library.add(pickedFiles: urls)
            }
        }
    }
}

/// iPod Mode's own settings entry (was a bare toggle in Appearance): the enable switch plus the
/// click-wheel and screen colours, read by `IPodView`.
struct IPodSettingsView: View {
    @AppStorage(Pref.iPodMode) private var iPodMode = false
    @AppStorage(Pref.ipodWheelColour) private var wheelHex = ""
    @AppStorage(Pref.ipodScreenColour) private var screenHex = ""

    var body: some View {
        List {
            Section {
                Toggle("iPod Mode", isOn: $iPodMode)
            } footer: {
                Text("A classic click-wheel player over your library. Also available as a Create widget.")
            }
            Section {
                colorRow("Wheel", $wheelHex, defaultColour: Color(white: 0.85))
                colorRow("Screen", $screenHex, defaultColour: Color(red: 0.78, green: 0.85, blue: 0.78))
                if !wheelHex.isEmpty || !screenHex.isEmpty {
                    Button("Reset Colours") { wheelHex = ""; screenHex = "" }
                }
            } header: {
                Text("Colours")
            }
        }
        .navigationTitle("iPod Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func colorRow(_ label: String, _ hex: Binding<String>, defaultColour: Color) -> some View {
        ColorPicker(label, selection: Binding(
            get: { hex.wrappedValue.isEmpty ? defaultColour : Pref.color(for: hex.wrappedValue) },
            set: { hex.wrappedValue = Pref.hex(of: $0) }
        ), supportsOpacity: false)
    }
}

/// Preset accent swatches: a tap-to-pick group like the icon gallery, the icon's
/// tape-square red among them. A custom colour outside the presets shows as an extra ringed dot.
private struct AccentSwatches: View {
    @Binding var theme: String
    @Binding var custom: String     // comma-joined saved custom hexes; hold one to remove it

    private let dot: CGFloat = 30

    private var customHexes: [String] { custom.split(separator: ",").map(String.init) }

    var body: some View {
        // Wraps if the user saves several custom presets; a plain HStack would clip.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Pref.accentPresets, id: \.hex) { preset in
                    swatch(hex: preset.hex, selected: theme.uppercased() == preset.hex)
                }
                ForEach(customHexes, id: \.self) { hex in
                    swatch(hex: hex, selected: theme.uppercased() == hex)
                        .contextMenu {
                            Button(role: .destructive) {
                                custom = customHexes.filter { $0 != hex }.joined(separator: ",")
                                if theme.uppercased() == hex { theme = "" }
                            } label: { Label("Remove Preset", systemImage: "trash") }
                        }
                }
                // A picked colour that isn't saved anywhere still shows its selection.
                if !theme.isEmpty,
                   !Pref.accentPresets.contains(where: { $0.hex == theme.uppercased() }),
                   !customHexes.contains(theme.uppercased()) {
                    swatch(hex: theme, selected: true)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 2)
        }

    }

    private func swatch(hex: String, selected: Bool) -> some View {
        Button { theme = hex } label: {
            Circle()
                .fill(Pref.color(for: hex))
                .frame(width: dot, height: dot)
                // White needs an outline to be visible on the dark row.
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: hex.isEmpty ? 1 : 0))
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0)
                    .padding(-4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Pref.accentPresets.first { $0.hex == hex }?.name ?? "Custom")
    }
}

/// Where sidecar metadata/lyrics get written: beside the music (default) or one folder the
/// user picks. Shows the active path so it's never a mystery.
struct SidecarLocationView: View {
    @Environment(LibraryStore.self) private var library
    @State private var picking = false

    var body: some View {
        List {
            Section {
                Button {
                    library.setCustomSidecarFolder(nil)
                } label: {
                    HStack {
                        Text("Beside the music files")
                        Spacer()
                        if library.customSidecarFolderName == nil {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        }
                    }
                }
                .tint(.primary)
                Button {
                    picking = true
                } label: {
                    HStack {
                        Text(library.customSidecarFolderName.map { "Folder: \($0)" } ?? "Choose a Folder…")
                        Spacer()
                        if library.customSidecarFolderName != nil {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        }
                    }
                }
                .tint(.primary)
            } footer: {
                Text("Tags (.verse.json) and lyrics (.lrc) save here. Beside the files keeps everything with your music (survives app wipes); a separate folder keeps your music folders untouched. Re-import reads both locations.")
            }
        }
        .navigationTitle("Metadata Location")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.setCustomSidecarFolder(url) }
        }
    }
}

/// Every font drawn in its own face — the row IS the preview.
struct LyricsFontPicker: View {
    @Binding var selection: String

    var body: some View {
        List(Pref.lyricFonts, id: \.id) { f in
            Button { selection = f.id } label: {
                HStack {
                    Text(f.name).font(Pref.lyricsFont(id: f.id, size: 20))
                    Spacer()
                    if selection == f.id { Image(systemName: "checkmark").fontWeight(.semibold) }
                }
            }
            .tint(.primary)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Lyrics Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Icon gallery: each choice shown as the actual icon, tap to apply. `id` is the alternate
/// icon name handed to setAlternateIconName (nil = the primary).
struct IconPickerView: View {
    @Binding var appIcon: String?

    static let icons: [(id: String?, label: String, preview: String)] = [
        (nil, "Verse", "IconPreview-Verse"),   // the classic green/violet disc, primary
        ("AppIcon-Yeezus", "Yeezus", "IconPreview-Yeezus"),
        ("AppIcon-Yandhi", "Yandhi", "IconPreview-Yandhi"),
    ]

    var body: some View {
        List(Self.icons, id: \.label) { icon in
            Button {
                appIcon = icon.id
                UIApplication.shared.setAlternateIconName(icon.id)
            } label: {
                HStack(spacing: 14) {
                    Image(icon.preview)
                        .resizable().scaledToFit()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 13.5))  // 60pt icon curvature
                    Text(icon.label)
                    Spacer()
                    if appIcon == icon.id {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                }
            }
            .tint(.primary)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Fetch review (#6a): ONE scrolling list of every local track with a coloured state dot — no
/// tabs. Conflicts and gaps pin to the top by default because they are the rows wanting a
/// decision; ignored and found sit below. Tapping a dot explains the state; tapping the row opens
/// the finder that can actually resolve it. Every dot is computed live from the store and the
/// artwork/lyrics caches, so a row re-tags itself the moment its lookup lands.
extension FetchState {
    /// The review dot's colour, shared with Home's status tile (#5) so one state never reads two
    /// different ways.
    var tint: Color {
        switch self {
        case .conflict: .orange
        case .missing: .red
        case .ignored: .gray
        case .found: .green
        }
    }
}

struct FetchReviewView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Coordinator.self) private var coordinator
    @State private var order: Order = .needsAttention
    @State private var explain: FetchState?
    @State private var finderAlbum: AlbumPick?
    @State private var lyricsItem: LibraryItem?

    /// `AlbumRef` is a navigation value (Hashable, not Identifiable), and `sheet(item:)` needs
    /// identity — so the sheet gets its own tiny wrapper rather than the shared type growing a
    /// conformance it doesn't otherwise want.
    private struct AlbumPick: Identifiable { let id: String }

    /// The "smart/concise" control: one menu, three orders. Not tabs, not a filter that hides
    /// rows — everything stays in the one list.
    enum Order: String, CaseIterable, Identifiable {
        case needsAttention = "Needs Attention", byState = "By State", alphabetical = "A–Z"
        var id: String { rawValue }
    }

    /// Local files only — a YouTube entry has no album folder or sidecar to fetch into.
    private var tracks: [LibraryItem] {
        library.items.filter { if case .file = $0.source { true } else { false } }
    }

    /// Every track's state, computed once per render. `reviewState` stats the artwork and lyrics
    /// caches, and this screen asks for it from a sort comparator, a per-state filter, the sheet's
    /// count and every row — so it has to be a lookup by the time any of those run.
    private var states: [UUID: FetchState] {
        let excluded = LibraryStore.excludedFolders()
        return Dictionary(uniqueKeysWithValues:
            tracks.map { ($0.id, library.reviewState(for: $0, excluded: excluded)) })
    }

    private func sorted(_ list: [LibraryItem], _ states: [UUID: FetchState]) -> [LibraryItem] {
        switch order {
        case .alphabetical:
            list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .needsAttention, .byState:
            list.sorted {
                let a = states[$0.id] ?? .found, b = states[$1.id] ?? .found
                return a == b
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : a < b
            }
        }
    }

    var body: some View {
        let states = self.states
        List {
            if tracks.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checklist",
                                       description: Text("Import some files and run a fetch."))
            } else if order == .byState {
                // Grouped is still one list — section headers, not tabs.
                ForEach(FetchState.allCases) { state in
                    let rows = tracks.filter { states[$0.id] == state }
                    if !rows.isEmpty {
                        Section(state.rawValue) {
                            ForEach(sorted(rows, states)) { row($0, states[$0.id] ?? .found) }
                        }
                    }
                }
            } else {
                ForEach(sorted(tracks, states)) { row($0, states[$0.id] ?? .found) }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Order", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $explain) { state in
            StateExplainerSheet(state: state,
                                count: states.values.filter { $0 == state }.count)
        }
        .sheet(item: $finderAlbum) { AlbumFinderSheet(albumName: $0.id) }
        .sheet(item: $lyricsItem) { LyricsFinderSheet(item: $0, player: coordinator.player) }
    }

    private func row(_ item: LibraryItem, _ state: FetchState) -> some View {
        let gaps = library.missingFields(of: item)
        return Button { resolve(item, state: state, gaps: gaps) } label: {
            HStack(spacing: 10) {
                // The dot is its own button so tapping it explains rather than navigates.
                Button { explain = state } label: {
                    Circle().fill(state.tint).frame(width: 10, height: 10)
                        .padding(6)          // a 10pt dot is not a tap target on its own
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Text(state == .found
                         ? state.rawValue
                         : "\(state.rawValue) · \(gaps.map(\.label).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .tint(.primary)
    }

    /// Open whatever can fix this row: the album finder when a tag or cover is absent (it fixes
    /// the whole folder at once), the lyrics finder when lyrics are the only gap.
    private func resolve(_ item: LibraryItem, state: FetchState, gaps: [MetaField]) {
        if gaps.contains(.album) || gaps.contains(.artwork) || state == .conflict {
            if !item.albumKey.isEmpty { finderAlbum = AlbumPick(id: item.albumKey) }
        } else if gaps.contains(.lyrics) {
            lyricsItem = item
        }
    }
}

/// What a dot means, slid up from the row that owns it (#6a).
private struct StateExplainerSheet: View {
    let state: FetchState
    let count: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(state.explanation)
                } header: {
                    Text("\(count) track\(count == 1 ? "" : "s")")
                }
            }
            .navigationTitle(state.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.height(260)])
        .themedTint()
    }
}
