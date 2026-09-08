import SwiftUI
import MediaPlayer
import UIKit

struct PlayerView: View {
    @Environment(Coordinator.self) private var coordinator

    var body: some View {
        switch coordinator.engine {
        case .airplay: VideoPane()
        case .vlc: NowPlayingPane(player: coordinator.player)
        }
    }
}

// MARK: - Audio: Spotify-shaped now playing

private struct NowPlayingPane: View {
    let player: Player
    @Environment(Coordinator.self) private var coordinator
    @Environment(LibraryStore.self) private var library
    @State private var showLyrics = false
    @State private var infoItem: LibraryItem?
    @State private var showQueue = false
    @State private var showReactions = false
    @State private var showGlyphBrowser = false
    @State private var showLyricsFinder = false

    private var hasLyrics: Bool {
        guard let l = player.lyrics else { return false }
        return l.isSynced || l.plain != nil
    }

    @AppStorage(Pref.tintedBackground) private var tintedBG = false
    @AppStorage(Pref.likeGlyph) private var likeGlyph = "heart"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Optional cover-tinted wash (Settings › Lyrics › Tinted Background). Solid dim
            // colour, not a gradient — the no-gradient rule holds.
            if tintedBG, let art = player.current?.artwork,
               let c = Artwork.dominantColor(art) {
                Color(c).opacity(0.18).ignoresSafeArea()
            }

            if showLyrics, let lyrics = player.lyrics, hasLyrics {
                LyricsScreen(player: player, lyrics: lyrics, showQueue: $showQueue) {
                    withAnimation(.snappy) { showLyrics = false }
                }
            } else {
                VStack(spacing: 0) {
                    topBar

                    // Album art near the top, offset so it doesn't crowd the top bar.
                    artOrVideo
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 300)
                        .padding(.top, 32)
                    titleRow.padding(.top, 28)
                    scrubber.padding(.top, 8)
                    transport
                    // Wider gaps around the volume row (#10) — it was crowding the transport
                    // above it and the option icons below.
                    volumeRow.padding(.top, 14)
                    bottomRow

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
            }
        }
        .sheet(item: $infoItem) { InfoSheet(item: $0) }
        .sheet(isPresented: $showGlyphBrowser) { ReactionBrowser(selected: $likeGlyph) }
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .sheet(isPresented: $showLyricsFinder) {
            if let item = coordinator.nowPlayingItem {
                LyricsFinderSheet(item: item, player: player)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Top: just the options (•••) menu, top right. This is the ONLY glass control on the player
    /// — the bottom row and the favourite are bare. Minimize is gone; the sheet's own
    /// swipe-down dismiss covers it (#3).
    private var topBar: some View {
        HStack {
            Spacer()
            optionsMenu
        }
        .padding(.top, 14)
    }

    private var optionsMenu: some View {
        Menu {
            if let item = coordinator.nowPlayingItem {
                Button { infoItem = item } label: { Label("Info", systemImage: "info.circle") }
                // Only library files live somewhere to view; remote queue entries don't.
                if case .file = item.source {
                    // Album page, not the disk folder — file locations never display.
                    Button {
                        coordinator.open(item.albumKey.isEmpty ? .folder([]) : .album(item.albumKey))
                    } label: {
                        Label("View Album", systemImage: "square.stack")
                    }
                }
                if !item.artist.isEmpty {
                    Button { coordinator.open(.artist(item.artist)) } label: {
                        Label("View Artist", systemImage: "music.mic")
                    }
                }
                // #6g: only when this track has none — with lyrics present there is nothing to
                // go looking for.
                if !hasLyrics, case .file = item.source {
                    Divider()
                    Button { showLyricsFinder = true } label: {
                        Label("Find Lyrics", systemImage: "quote.bubble")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive())
        }
    }

    /// Tap = like/unlike the current track; hold = the reaction strip, which picks the glyph the
    /// button wears (`Pref.likeGlyph`). Bare, no glass — glass is the top options button only
    ///. Sits where the options menu used to, right of the title.
    private var favouriteButton: some View {
        let item = coordinator.nowPlayingItem
        let liked = item.map { i in library.items.first { $0.id == i.id }?.liked ?? i.liked } ?? false
        return Image(systemName: liked ? "\(likeGlyph).fill" : likeGlyph)
            .font(.body.weight(.semibold))
            .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.8)))
            .frame(width: 34, height: 34)
            // A Menu can't host a custom row of glyphs, so tap and hold are wired by hand.
            .contentShape(Rectangle())
            .onTapGesture {
                guard var it = item else { return }
                it.liked.toggle()
                library.update(it)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                withAnimation(.snappy) { showReactions.toggle() }
            }
            .opacity(item == nil ? 0.35 : 1)
            .allowsHitTesting(item != nil)
            // Inline, not a popover (#9): the strip floats directly above the button in an
            // overlay so it can't push the title row around while it's open.
            .overlay(alignment: .bottomTrailing) {
                if showReactions {
                    ReactionStrip(selected: $likeGlyph,
                                  onPick: { withAnimation(.snappy) { showReactions = false } },
                                  onBrowse: {
                                      showReactions = false
                                      showGlyphBrowser = true
                                  })
                        .fixedSize()
                        .offset(y: -46)
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
    }

    /// Locked repeat wears an ∞ where `repeat.1` wears its numeral (#12). SF Symbols has no
    /// "repeat.infinity", so it's a plain `repeat` with the badge overlaid in the same corner.
    @ViewBuilder private var repeatGlyph: some View {
        if coordinator.repeatLocked {
            Image(systemName: "repeat")
                .overlay(alignment: .center) {
                    Image(systemName: "infinity")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 1)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
        } else {
            Image(systemName: coordinator.repeatMode == .one ? "repeat.1" : "repeat")
        }
    }

    /// System volume, below the transport (#1). MPVolumeView drives the real hardware volume;
    /// route button hidden (AirPlay already lives in the bottom row). Simulator shows it inert.
    ///
    /// Deliberately quieter than the song scrubber (#10) — same shape read as a second scrubber
    /// at a glance. Both icons get one fixed width so the slider sits centred between them;
    /// `speaker.wave.3.fill` is much wider than `speaker.fill`, which is what pushed it off.
    private var volumeRow: some View {
        HStack(spacing: 18) {
            Image(systemName: "speaker.fill")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .frame(width: 18)
            SystemVolumeSlider().frame(height: 28).opacity(0.65)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .frame(width: 18)
        }
        .padding(.horizontal, 8)
    }

    /// Share the current track's URL. Lives *in* the bottom row beside the four options now
    ///, not on a row of its own, and carries no glass.
    @ViewBuilder private var shareButton: some View {
        if let item = coordinator.nowPlayingItem, let url = shareURL(item) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
        } else {
            // Hold the slot so the other four don't shuffle sideways when sharing isn't possible.
            Color.clear.frame(width: 34, height: 34)
        }
    }

    private func shareURL(_ item: LibraryItem) -> URL? {
        switch item.source {
        case .youtube(let watchURL): watchURL.scheme?.hasPrefix("http") == true ? watchURL : nil
        case .file: library.resolveURL(item)
        }
    }

    @ViewBuilder private var artOrVideo: some View {
        // Square corners on the art, per the redesign — no rounding anywhere here.
        // Gate on the ITEM being video, not duration>0 — coverless audio was rendering the
        // empty VLC surface instead of the placeholder (issue #8).
        if player.current?.artwork == nil, coordinator.nowPlayingItem?.isVideo == true {
            // VLC-only video (mkv/webm/…) draws here; audio shows the placeholder square.
            VideoSurface(view: player.videoView)
                .aspectRatio(16 / 9, contentMode: .fit)
        } else if let art = player.current?.artwork {
            // scaledToFit, not fill — fill zoom-crops non-square covers.
            Image(uiImage: art)
                .resizable().scaledToFit()
                .shadow(radius: 20)
        } else {
            Rectangle()
                .fill(.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.4)))
        }
    }

    /// Apple-Music-shaped: title/artist left, the favourite button on the right (#3).
    private var titleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.current?.title ?? "")
                    .font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            favouriteButton
        }
        .padding(.top, 12)
    }

    /// Apple Music's bottom row: lyrics, sleep timer, AirPlay, queue — plus Share, which used to
    /// sit on its own row below. Plain glyphs, no glass (note: glass is the top button only).
    private var bottomRow: some View {
        HStack {
            Button { withAnimation(.snappy) { showLyrics = true } } label: {
                Image(systemName: "quote.bubble.fill")
                    .font(.body)
                    .foregroundStyle(hasLyrics ? .white : .white.opacity(0.25))
                    .frame(width: 34, height: 34)
            }
            .disabled(!hasLyrics)
            Spacer()
            sleepMenu
            Spacer()
            AirPlayButton()
                .frame(width: 34, height: 34)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            Spacer()
            shareButton
        }
        // 24, not 32: five icons need the extra width the old four didn't.
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    /// Sleep timer (moved off Settings): a moon that fills while a timer is running; the menu shows
    /// the remaining minutes and lets you change or cancel it.
    private var sleepMenu: some View {
        Menu {
            if let m = coordinator.sleepMinutes {
                Text("~\(m) min left")
                Button("Cancel Timer") { coordinator.setSleepTimer(minutes: nil) }
                Divider()
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) min") { coordinator.setSleepTimer(minutes: m) }
            }
        } label: {
            Image(systemName: coordinator.sleepMinutes != nil ? "moon.fill" : "moon")
                .font(.body)
                .foregroundStyle(coordinator.sleepMinutes != nil ? .white : .white.opacity(0.6))
                .frame(width: 34, height: 34)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { min(player.position, max(player.duration, 1)) },
                                  set: { player.seek(to: $0) }),
                   in: 0 ... max(player.duration, 1))
                .tint(.white)
            HStack {
                Text(timeString(player.position))
                Spacer()
                Text(timeString(player.duration))
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
        }
        .padding(.top, 8)
    }

    private var transport: some View {
        HStack {
            Button { coordinator.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(coordinator.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.6)))
            }
            Spacer()
            Button { player.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular.interactive())
            }
            Spacer()
            Button { player.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            Spacer()
            // Tap cycles; hold locks repeat-one and makes tap a no-op until the next hold (#12).
            // Hand-wired like the favourite button above, and for the same reason — a Button with
            // a long press attached fires both on release. Same .rigid impact, so the two holds
            // feel alike.
            repeatGlyph
                .font(.title3)
                .foregroundStyle(coordinator.repeatMode == .off ? AnyShapeStyle(.white.opacity(0.6)) : AnyShapeStyle(.tint))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .onTapGesture { coordinator.cycleRepeat() }
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.snappy) { coordinator.toggleRepeatLock() }
                }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 18)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// Manual lyrics finder (#6g), reached from the player's ••• menu when the current track has no
/// lyrics. Same shape as the album finders: results list, search bar pinned to the bottom with
/// sort + filter (#6d/e/f). LRCLIB's `q` already matches artist as well as track, so typing an
/// artist pivots to their songs for free. Picking one attaches it to the track and lights it up
/// in the player immediately.
struct LyricsFinderSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let player: Player

    @State private var candidates: [LRCLibClient.Candidate] = []
    @State private var loading = true
    @State private var query = ""
    @State private var sort: FinderSort = .relevance
    @State private var syncedOnly = false
    @State private var failed = false

    private var shown: [LRCLibClient.Candidate] {
        sort.apply(syncedOnly ? candidates.filter(\.synced) : candidates)
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                } else if shown.isEmpty {
                    ContentUnavailableView("No lyrics found", systemImage: "quote.bubble",
                                           description: Text(failed
                                               ? "LRCLIB could not be reached. Try again in a moment."
                                               : candidates.isEmpty
                                                   ? "LRCLIB had nothing for “\(query)”. Edit the search below and try again."
                                                   : "Every result was filtered out. Turn off “Only synced” below."))
                }
                ForEach(shown) { c in
                    Button { apply(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.track).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Find Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                FinderSearchBar(query: $query, sort: $sort, matchingOnly: $syncedOnly,
                                filterLabel: "Only synced",
                                sortOptions: FinderSort.songOptions,
                                placeholder: "Search LRCLIB", onSearch: runSearch)
            }
        }
        .themedTint()
        .task {
            // Seed with what the track claims to be, which is what the automatic pass used.
            query = [item.artist, item.title].filter { !$0.isEmpty }.joined(separator: " ")
            await search(query)
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { await search(q) }
    }

    private func search(_ q: String) async {
        loading = true
        failed = false
        do { candidates = try await LRCLibClient().candidates(query: q) }
        catch { candidates = []; failed = true }
        loading = false
    }

    /// Attach, sidecar, and push it into the running player so the lyrics button lights up
    /// without waiting for the next load.
    private func apply(_ c: LRCLibClient.Candidate) {
        library.attachLyrics(c.raw, to: item)
        if let url = player.current?.url {
            player.attach(lyrics: LRCParser.parse(c.raw), artwork: nil, forURL: url)
        }
        dismiss()
    }
}

/// Fullscreen lyrics, Files-app player shaped: close top right, a bare scrubber (no transport on
/// it), play bottom left, queue bottom right, with the track pill staying visible above the bar.
private struct LyricsScreen: View {
    let player: Player
    let lyrics: Lyrics
    @Binding var showQueue: Bool
    let onClose: () -> Void
    @State private var samples: [Float]?
    @AppStorage(Pref.lyricsCoverColour) private var coverColour = false

    /// The active-line tint: the cover's dominant colour when the setting is on and there's
    /// artwork, otherwise stock white.
    private var lineTint: Color {
        guard coverColour, let art = player.current?.artwork,
              let c = Artwork.dominantColor(art) else { return .white }
        return Color(c)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Files-style top bar: track name centered, close right. The clear square mirrors
            // the close button so the title actually centers.
            HStack {
                Color.clear.frame(width: 34, height: 34)
                Spacer()
                // .headline = the one title style used on inline bars app-wide.
                Text(player.current?.title ?? "")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular.interactive())
                }
            }
            .padding(.top, 14)

            LyricsPane(lyrics: lyrics, position: player.position, tint: lineTint) { player.seek(to: $0) }

            // The wave alone in a capsule, no name (the top bar carries it) — same pill
            // language as the dock mini player, per reference/files-layer.png. Real audio when
            // AVFoundation can decode the file; Files-style ticks when it can't (VLC-only
            // codecs, remote streams — VLC exposes no decoded samples).
            WaveScrubber(samples: samples,
                         position: player.position,
                         duration: player.duration) { player.seek(to: $0) }
                .frame(height: 30)
                .padding(.horizontal, 14).padding(.vertical, 9)
                // Glass, not a flat white wash — matches the pill language elsewhere.
                .glassEffect(.regular, in: Capsule())
                .task(id: player.current?.url) {
                    samples = nil
                    if let url = player.current?.url { samples = await Waveform.load(url: url) }
                }

            HStack {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive())
                }
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive())
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
    }
}

/// The wave scrubber: real waveform bars when samples exist, Files-style ticks otherwise, with
/// a playhead line. Drag to seek. Shared by the lyrics pill and (via Settings) the mini player.
struct WaveScrubber: View {
    let samples: [Float]?
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let frac = duration > 0 ? min(max(position / duration, 0), 1) : 0
            let x = frac * w
            Canvas { ctx, _ in
                if let samples, !samples.isEmpty {
                    let step = w / CGFloat(samples.count)
                    for (i, v) in samples.enumerated() {
                        let dx = CGFloat(i) * step
                        let bh = max(3, CGFloat(v) * (h - 4))
                        ctx.fill(
                            Path(roundedRect: CGRect(x: dx, y: (h - bh) / 2,
                                                     width: max(step - 1.5, 1), height: bh),
                                 cornerRadius: 1),
                            with: .color(.white.opacity(dx < x ? 0.9 : 0.3)))
                    }
                } else {
                    for i in 0 ..< max(Int(w / 6), 2) {
                        let dx = CGFloat(i) * 6 + 1.5
                        ctx.fill(Path(ellipseIn: CGRect(x: dx, y: h / 2 - 1, width: 2, height: 2)),
                                 with: .color(.white.opacity(dx < x ? 0.9 : 0.35)))
                    }
                }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { g in
                        guard duration > 0 else { return }
                        onSeek(min(max(g.location.x / w, 0), 1) * duration)
                    })
        }
    }
}

/// The queue sheet: player-black background (the grouped-grey default looked like another
/// app), Now Playing pinned on top, Up Next below with drag-reorder (Edit) and swipe-remove.
private struct QueueSheet: View {
    @Environment(Coordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var infoItem: LibraryItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            if coordinator.nowPlayingItem != nil {
                // Same widget card as Home — above the List so it gets no row chrome
                // (separators, edit-mode insets), just its own rounded card.
                NowPlayingCard(player: coordinator.player)
                    .padding(14)
                    .background(Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            List {
                Section {
                    if coordinator.upNext.isEmpty {
                        Text("Nothing queued — hold a song and Add to Queue.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        // No onDelete: that's what drew the minus circles in edit mode. The
                        // handle only reorders; removal is swipe or the hold menu.
                        ForEach(coordinator.upNext) { item in
                            Button { coordinator.jumpTo(item) } label: { QueueRow(item: item) }
                                .tint(.primary)
                                .listRowBackground(Color.clear)
                                .swipeActions {
                                    Button(role: .destructive) { remove(item) } label: {
                                        Label("Remove", systemImage: "minus.circle")
                                    }
                                }
                                .contextMenu {
                                    Button { remove(item) } label: {
                                        Label("Remove from Queue", systemImage: "minus.circle")
                                    }
                                    ItemContextMenu(item: item, queue: coordinator.upNext,
                                                    infoItem: $infoItem)
                                }
                        }
                        .onMove { coordinator.moveUpNext(from: $0, to: $1) }
                    }
                } header: {
                    Text("Up Next").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Always-on drag handles on the right — no Edit mode dance. Swipe deletes.
            .environment(\.editMode, .constant(.active))
            }
            .background(Color.black)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationBackground(Color.black)
        .themedTint()
        .preferredColorScheme(.dark)
        .modifier(TrackSheets(infoItem: $infoItem))
    }

    private func remove(_ item: LibraryItem) {
        if let i = coordinator.upNext.firstIndex(of: item) {
            coordinator.removeUpNext(at: IndexSet(integer: i))
        }
    }
}

private struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context _: Context) -> UIView { view }
    func updateUIView(_: UIView, context _: Context) {}
}

/// System volume slider — MPVolumeView with its route button hidden, so it's just the slider
/// wired to real hardware volume. Inert in the simulator (no volume there).
///
/// Lighter than the song scrubber on purpose (#10): dimmed tint and a small thumb, so the two
/// bars don't read as the same control.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context _: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.showsRouteButton = false
        v.tintColor = UIColor.white.withAlphaComponent(0.55)
        v.setVolumeThumbImage(Self.thumb, for: .normal)
        return v
    }
    func updateUIView(_: MPVolumeView, context _: Context) {}

    /// 10pt dot — the default thumb is scrubber-sized and it's what made the two bars twins.
    private static let thumb: UIImage = {
        let d: CGFloat = 10
        return UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { ctx in
            UIColor.white.withAlphaComponent(0.8).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
    }()
}

/// Synced lyric sheet, Spotify-style: bold lines, active one lit, tap to seek, auto-scroll.
private struct LyricsPane: View {
    let lyrics: Lyrics
    let position: TimeInterval
    var tint: Color = .white
    let onSeek: (TimeInterval) -> Void
    @AppStorage(Pref.lyricsFont) private var fontDesign = "system"
    @AppStorage(Pref.lyricsSize) private var fontSize = 22.0

    private var lineFont: Font { Pref.lyricsFont(id: fontDesign, size: fontSize) }

    var body: some View {
        if lyrics.isSynced {
            let current = lyrics.lineIndex(at: position)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(lineFont)
                                .foregroundStyle(i == current ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.35)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                                .onTapGesture { onSeek(line.time + lyrics.offset) }
                        }
                    }
                    .padding(.vertical, 80)
                }
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        } else if let plain = lyrics.plain {
            ScrollView {
                Text(plain)
                    .font(lineFont)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 40)
            }
        }
    }
}

// MARK: - Video: YouTube-shaped watch screen

private struct VideoPane: View {
    @Environment(Coordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if coordinator.airPlayer.isExternal {
                    ContentUnavailableView("Playing on car display",
                                           systemImage: "car",
                                           description: Text("Video returns here when you disconnect."))
                } else {
                    AirPlayVideoView(player: coordinator.airPlayer.player)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)

            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(coordinator.nowTitle).font(.headline).lineLimit(2)
                        Text(coordinator.nowArtist).font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)

                    HStack(spacing: 24) {
                        Button {
                            coordinator.airPlayer.isPlaying
                                ? coordinator.airPlayer.player.pause()
                                : coordinator.airPlayer.player.play()
                        } label: {
                            Image(systemName: coordinator.airPlayer.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Button { coordinator.skip(-1) } label: { Image(systemName: "backward.fill") }
                        Button { coordinator.skip(1) } label: { Image(systemName: "forward.fill") }
                        Spacer()
                        AirPlayButton().frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                }

                if !coordinator.upNext.isEmpty {
                    Section("Up next") {
                        ForEach(coordinator.upNext) { item in
                            Button { coordinator.jumpTo(item) } label: {
                                QueueRow(item: item)
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(.dark)
    }
}

private struct QueueRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 10) {
            // Album cover first (local cache); YouTube thumb as fallback.
            Group {
                if let img = Artwork.thumb(for: item.id.uuidString) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    AsyncImage(url: item.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: item.isVideo ? "film" : "music.note")
                                .foregroundStyle(.secondary))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(2)
                if !item.artist.isEmpty {
                    Text(item.artist).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
