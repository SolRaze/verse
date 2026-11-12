@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI

/// Lyric Studio: lines from a song over video. Pick the song and a lyric range, fill the range
/// with clips from the camera or the photo library, cut and reorder them, export.
struct StudioView: View {
    @Environment(Coordinator.self) private var coordinator
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model: StudioModel?
    @State private var problem: String?
    /// A draft exists on disk but could not open. Setup must not replace it until discarded.
    @State private var stuckDraft = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    StudioEditor(model: model) {
                        model.close()
                        self.model = nil
                    }
                } else {
                    StudioSetup { project, songURL, lyrics in
                        if stuckDraft { problem = Self.stuckMessage; return }
                        model = StudioModel(project: project, songURL: songURL, lyrics: lyrics)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .themedTint()
        .preferredColorScheme(.dark)
        .alert("Lyric Studio", isPresented: .init(get: { problem != nil },
                                                  set: { if !$0 { problem = nil } })) {
            if stuckDraft {
                Button("Discard Draft", role: .destructive) {
                    StudioProject.discardDraft()
                    stuckDraft = false
                }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .onDisappear { model?.close() }
        .task {
            // The studio plays the song itself; two players on one song is noise.
            coordinator.player.pause()
            guard model == nil, StudioProject.hasDraft else { return }
            guard let draft = StudioProject.loadDraft(),
                  let item = library.items.first(where: { $0.id == draft.songID }),
                  let (url, lyrics) = await StudioSetup.source(for: item, library: library,
                                                               raw: draft.lyricsRaw)
            else {
                stuckDraft = true
                problem = Self.stuckMessage
                return
            }
            model = StudioModel(project: draft, songURL: url, lyrics: lyrics)
        }
    }

    private static let stuckMessage = "The saved draft could not open: its song or lyrics are missing. Bring the song back, or discard the draft to start over."
}

// MARK: - Setup: song and lyric range

private struct StudioSetup: View {
    @Environment(Coordinator.self) private var coordinator
    @Environment(LibraryStore.self) private var library
    let onReady: (StudioProject, URL, Lyrics) -> Void

    @State private var item: LibraryItem?
    @State private var songURL: URL?
    @State private var lyrics: Lyrics?
    @State private var first: Int?
    @State private var last: Int?
    @State private var problem: String?
    @State private var picking = false

    /// Seconds the marked range covers, to the start of the line after it.
    private var span: (start: Double, length: Double)? {
        guard let lyrics, let first else { return nil }
        let end = last ?? first
        let start = lyrics.lines[first].time + lyrics.offset
        let stop = end + 1 < lyrics.lines.count
            ? lyrics.lines[end + 1].time + lyrics.offset
            : lyrics.lines[end].time + lyrics.offset + Lyrics.maxLineSpan
        return (start, stop - start)
    }

    var body: some View {
        List {
            Section {
                Button { picking = true } label: {
                    LabeledContent("Song", value: item?.title ?? "Choose")
                }
                .tint(.primary)
            } footer: {
                if let problem { Text(problem) }
            }
            if let lyrics {
                Section {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        if !line.text.isEmpty {
                            Button { mark(i) } label: {
                                Text(line.text)
                                    .foregroundStyle(inRange(i) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .fontWeight(inRange(i) ? .semibold : .regular)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityAddTraits(inRange(i) ? .isSelected : [])
                        }
                    }
                } header: {
                    Text("Lines")
                } footer: {
                    Text("Tap the first line, then the last. Up to \(Int(StudioProject.maxRange)) seconds.")
                }
            }
        }
        .navigationTitle("Lyric Studio")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let span, let item, let songURL, let lyrics {
                Button {
                    onReady(StudioProject(songID: item.id, songTitle: item.title,
                                          songStart: span.start,
                                          songDuration: min(span.length, StudioProject.maxRange),
                                          lyricsRaw: LyricsResolver.cachedRaw(for: item.id.uuidString)),
                            songURL, lyrics)
                } label: {
                    Text("Use \(Int(min(span.length, StudioProject.maxRange).rounded())) Seconds")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $picking) {
            SongPicker { picked in Task { await choose(picked) } }
        }
        .task {
            if item == nil, let playing = coordinator.nowPlayingItem { await choose(playing) }
        }
    }

    private func inRange(_ i: Int) -> Bool {
        guard let first else { return false }
        return i >= first && i <= (last ?? first)
    }

    /// First tap starts the range, a later line ends it, anything else starts over.
    private func mark(_ i: Int) {
        if let f = first, last == nil, i > f { last = i } else { first = i; last = nil }
    }

    private func choose(_ picked: LibraryItem) async {
        item = picked
        lyrics = nil
        songURL = nil
        first = nil
        last = nil
        problem = nil
        guard case .file = picked.source else {
            problem = "Streams cannot be used. Pick a song that is a file in the library."
            return
        }
        let found = await Self.source(for: picked, library: library)
        // A later pick may have landed during the await; only the latest one fills the state.
        guard item?.id == picked.id else { return }
        guard let (url, found) = found else {
            problem = "This song needs synced lyrics and a format the studio can read (MP3, M4A, FLAC, WAV, AIFF). Play it once so its lyrics are fetched."
            return
        }
        songURL = url
        lyrics = found
    }

    /// The song's file and synced lyrics, or nil when either is missing or unreadable. The
    /// security scope on the file is taken here and held for the life of the app session.
    /// ponytail: scope is never released; one handle per studio song, add a stop on close if
    /// the studio ever opens many songs in one run.
    /// `raw` is a draft's own LRC text; nil reads the lyrics cache.
    static func source(for item: LibraryItem, library: LibraryStore,
                       raw: String? = nil) async -> (URL, Lyrics)? {
        guard case .file = item.source, let url = library.resolveURL(item),
              let raw = raw ?? LyricsResolver.cachedRaw(for: item.id.uuidString), !raw.isEmpty
        else { return nil }
        let lyrics = LRCParser.parse(raw)
        guard lyrics.isSynced else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        guard await StudioComposer.canUse(song: url) else { return nil }
        return (url, lyrics)
    }
}

private struct SongPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onPick: (LibraryItem) -> Void
    @State private var query = ""

    private var songs: [LibraryItem] {
        let files = library.items.filter { if case .file = $0.source { !$0.isVideo } else { false } }
        guard !query.isEmpty else { return files }
        return files.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(songs) { song in
                Button {
                    onPick(song)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).lineLimit(1)
                        if !song.artist.isEmpty {
                            Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .tint(.primary)
            }
            .searchable(text: $query)
            .navigationTitle("Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .themedTint()
    }
}

// MARK: - Model

@MainActor
@Observable
final class StudioModel {
    private(set) var project: StudioProject
    let songURL: URL
    let lyrics: Lyrics

    let player = AVPlayer()
    private(set) var overlay: CALayer?
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    private(set) var exporting = false
    var problem: String?
    var exported: URL?

    private var undoStack: [[StudioClip]] = []
    private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Any?

    var clips: [StudioClip] { project.clips }
    var total: Double { StudioTimeline.total(project.clips) }
    var canUndo: Bool { !undoStack.isEmpty }
    /// Seconds of the lyric range not yet covered by a clip.
    var room: Double { max(0, project.songDuration - total) }
    var currentIndex: Int? { StudioTimeline.index(at: playhead, in: clips) }

    /// Timeline times of the lyric line starts inside the range, for the strip's marks and for
    /// snapping the playhead.
    var lineMarks: [Double] {
        lyrics.lines.compactMap { line in
            let t = line.time + lyrics.offset - project.songStart
            return t > 0 && t < project.songDuration && !line.text.isEmpty ? t : nil
        }
    }

    init(project: StudioProject, songURL: URL, lyrics: Lyrics) {
        self.project = project
        self.songURL = songURL
        self.lyrics = lyrics
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = time.seconds
                if time.seconds >= self.total - 0.05 { self.pause() }
            }
        }
        project.saveDraft()
        rebuild()
    }

    // MARK: edits

    private func commit(_ clips: [StudioClip]) {
        guard clips != project.clips else { return }
        undoStack.append(project.clips)
        if undoStack.count > 50 { undoStack.removeFirst() }
        project.clips = clips
        changed()
    }

    private func changed() {
        project.saveDraft()
        playhead = min(playhead, total)
        rebuild()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        project.clips = last
        changed()
    }

    func split() { commit(StudioTimeline.split(clips, at: playhead)) }
    func trimStart() {
        let start = currentIndex.map { StudioTimeline.start(of: $0, in: clips) }
        commit(StudioTimeline.trimStart(clips, at: playhead))
        if let start { seek(to: start) }
    }
    func trimEnd() { commit(StudioTimeline.trimEnd(clips, at: playhead)) }
    func deleteCurrent() {
        guard let i = currentIndex else { return }
        commit(StudioTimeline.remove(clips, id: clips[i].id))
    }
    func moveCurrent(by delta: Int) {
        guard let i = currentIndex else { return }
        let id = clips[i].id
        commit(StudioTimeline.move(clips, id: id, by: delta))
        if let now = clips.firstIndex(where: { $0.id == id }) {
            seek(to: StudioTimeline.start(of: now, in: clips))
        }
    }
    func toggleFade() {
        guard let i = currentIndex, i > 0 else { return }
        var next = clips
        next[i].fadeIn.toggle()
        commit(next)
    }

    /// Adds a video file already inside the studio folder at the playhead.
    func add(file: URL, fadeIn: Bool) async {
        // Length is the video track's, not the asset's: longer audio would leave a gap.
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let length = try? await track.load(.timeRange).duration.seconds, length.isFinite,
              length >= StudioTimeline.minClip
        else {
            problem = "That file has no video the studio can use."
            return
        }
        let at = min(playhead, total)
        let clip = StudioClip(file: file.lastPathComponent, sourceStart: 0, duration: length,
                              sourceDuration: length, fadeIn: fadeIn && at > 0)
        commit(StudioTimeline.insert(clip, into: clips, at: at, limit: project.songDuration))
    }

    func setLyricsY(_ y: Double) { project.lyricsY = min(max(y, 0.12), 0.9); changed() }
    func setWordByWord(_ on: Bool) { project.wordByWord = on; changed() }
    func setFontSize(_ size: Double) { project.fontSize = size; changed() }

    /// The frame the next take would follow: the end of the clip before the playhead.
    func ghostFrame() async -> CGImage? {
        guard !clips.isEmpty else { return nil }
        let at = min(playhead, total)
        guard at > 0 else { return nil }
        let before = clips.indices.last { StudioTimeline.start(of: $0, in: clips) < at } ?? 0
        var clip = clips[before]
        // Mid-clip, the take cuts in at the playhead, so that is the frame to match.
        clip.duration = min(clip.duration, at - StudioTimeline.start(of: before, in: clips))
        return await StudioComposer.lastFrame(of: clip)
    }

    // MARK: playback

    func play() {
        guard total > 0 else { return }
        if playhead >= total - 0.05 { seek(to: 0) }
        isPlaying = true
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    /// Ends the model's life: called when the studio drops it. An observer left on a player
    /// past that point is undefined behaviour per AVPlayer's docs.
    func close() {
        pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func seek(to time: Double) {
        playhead = min(max(time, 0), total)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func rebuild() {
        buildTask?.cancel()
        pause()
        buildTask = Task {
            guard let built = try? await StudioComposer.build(project, songURL: songURL),
                  !Task.isCancelled else { return }
            guard built.duration > 0 else {
                player.replaceCurrentItem(with: nil)
                overlay = nil
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            player.replaceCurrentItem(with: item)
            overlay = StudioComposer.overlay(project, built: built, lyrics: lyrics, flipped: false)
            seek(to: playhead)
        }
    }

    func export() async {
        pause()
        exporting = true
        defer { exporting = false }
        do { exported = try await StudioComposer.export(project, songURL: songURL, lyrics: lyrics) }
        catch { problem = error.localizedDescription }
    }
}

// MARK: - Editor

private struct StudioEditor: View {
    @Bindable var model: StudioModel
    /// Back to song and range setup, draft discarded.
    let onNew: () -> Void

    @State private var pickedVideo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var camera: CameraRequest?
    @State private var importing = false

    private struct CameraRequest: Identifiable {
        let id = UUID()
        let ghost: CGImage?
        let songTime: Double
    }

    var body: some View {
        VStack(spacing: 14) {
            preview
            if model.clips.isEmpty { emptyActions } else { strip; tools }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .navigationTitle(model.project.songTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Word by Word", isOn: Binding(get: { model.project.wordByWord },
                                                        set: { model.setWordByWord($0) }))
                    Picker("Lyrics Size", selection: Binding(get: { model.project.fontSize },
                                                            set: { model.setFontSize($0) })) {
                        Text("Small").tag(48.0)
                        Text("Medium").tag(64.0)
                        Text("Large").tag(84.0)
                    }
                    Divider()
                    Button("New Project", systemImage: "trash", role: .destructive) {
                        model.pause()
                        StudioProject.discardDraft()
                        onNew()
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Options")
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.exporting {
                    ProgressView()
                } else {
                    Button("Export") { Task { await model.export() } }
                        .disabled(model.clips.isEmpty)
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedVideo, matching: .videos)
        .onChange(of: pickedVideo) { _, picked in
            guard let picked else { return }
            pickedVideo = nil
            importing = true
            Task {
                if let video = try? await picked.loadTransferable(type: StudioVideoFile.self) {
                    await model.add(file: video.url, fadeIn: false)
                } else {
                    model.problem = "That video could not be copied in."
                }
                importing = false
            }
        }
        .fullScreenCover(item: $camera) { request in
            StudioCameraView(songURL: model.songURL, songTime: request.songTime,
                             room: max(model.project.songDuration - model.playhead, 1),
                             lyrics: model.lyrics, ghost: request.ghost) { url, ghosted in
                guard let url else { return }
                Task { await model.add(file: url, fadeIn: ghosted) }
            }
        }
        .sheet(item: Binding(get: { model.exported.map(ExportedFile.init) },
                             set: { if $0 == nil { model.exported = nil } })) { file in
            ShareSheet(url: file.url)
        }
        .alert("Lyric Studio", isPresented: .init(get: { model.problem != nil },
                                                  set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.problem ?? "") }
        .onDisappear { model.pause() }
    }

    private struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// 9:16 picture with the lyrics as they will export. Tap plays or pauses; dragging up or
    /// down moves the lyrics.
    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.06)
                if model.clips.isEmpty {
                    Image(systemName: "video").font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    StudioPlayerView(player: model.player, overlay: model.overlay)
                }
                if importing { ProgressView().controlSize(.large) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.isPlaying ? model.pause() : model.play() }
            .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                model.setLyricsY(drag.location.y / max(geo.size.height, 1))
            })
            .accessibilityElement()
            .accessibilityLabel("Preview")
            .accessibilityValue(model.isPlaying ? "Playing" : "Paused")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.isPlaying ? model.pause() : model.play() }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    private var emptyActions: some View {
        HStack(spacing: 12) {
            bigButton("Record", "video.fill") { openCamera() }
            bigButton("Add Video", "photo.on.rectangle") { showPhotos = true }
        }
        .padding(.bottom, 12)
    }

    private func bigButton(_ title: String, _ icon: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
        }
        .buttonStyle(.glass)
    }

    /// The whole lyric range across the screen width: clips as blocks, lyric line starts as
    /// marks, the playhead as a line. Drag anywhere to move the playhead; it snaps to a line
    /// start when close, with a tick.
    /// ponytail: fixed scale, 60 s is about 6 pt a second on a phone. Add a scrolling strip with
    /// pinch zoom when cuts need to be finer than that.
    private var strip: some View {
        GeometryReader { geo in
            let scale = geo.size.width / max(model.project.songDuration, 0.1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                HStack(spacing: 2) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, clip in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(i == model.currentIndex ? 0.5 : 0.22))
                            .overlay(alignment: .leading) {
                                if clip.fadeIn {
                                    Image(systemName: "circle.lefthalf.filled")
                                        .font(.caption2).padding(.leading, 4)
                                }
                            }
                            .frame(width: max(clip.duration * scale - 2, 2))
                    }
                }
                ForEach(model.lineMarks, id: \.self) { mark in
                    Rectangle().fill(.white.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: mark * scale)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                Rectangle().fill(.white).frame(width: 2)
                    .offset(x: model.playhead * scale - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                model.pause()
                var t = drag.location.x / scale
                if let near = model.lineMarks.min(by: { abs($0 - t) < abs($1 - t) }),
                   abs(near - t) * scale < 8, near <= model.total {
                    if abs(model.playhead - near) > 0.001 {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    t = near
                }
                model.seek(to: t)
            })
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Int(model.playhead)) of \(Int(model.total)) seconds")
        .accessibilityAdjustableAction { direction in
            model.seek(to: model.playhead + (direction == .increment ? 1 : -1))
        }
    }

    private var tools: some View {
        HStack(spacing: 0) {
            tool("Record", "video.fill", off: model.room < 1 && model.playhead >= model.total) {
                openCamera()
            }
            tool("Add", "plus", off: false) { showPhotos = true }
            tool("Split", "scissors", off: false) { model.split() }
            Menu {
                Button("Trim Start to Here", systemImage: "arrow.right.to.line") { model.trimStart() }
                Button("Trim End to Here", systemImage: "arrow.left.to.line") { model.trimEnd() }
                Divider()
                Button("Move Left", systemImage: "arrow.left") { model.moveCurrent(by: -1) }
                Button("Move Right", systemImage: "arrow.right") { model.moveCurrent(by: 1) }
                if let i = model.currentIndex, i > 0 {
                    Divider()
                    Toggle("Fade In From Last Clip", isOn: Binding(
                        get: { model.clips.indices.contains(i) && model.clips[i].fadeIn },
                        set: { _ in model.toggleFade() }))
                }
                Divider()
                Button("Delete Clip", systemImage: "trash", role: .destructive) {
                    model.deleteCurrent()
                }
            } label: {
                toolLabel("Clip", "rectangle.split.3x1")
            }
            tool("Undo", "arrow.uturn.backward", off: !model.canUndo) { model.undo() }
        }
    }

    private func tool(_ title: String, _ icon: String, off: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, icon) }
            .disabled(off)
    }

    private func toolLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).frame(height: 24)
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    private func openCamera() {
        model.pause()
        Task {
            let ghost = await model.ghostFrame()
            camera = CameraRequest(ghost: ghost,
                                   songTime: model.project.songStart + min(model.playhead, model.total))
        }
    }
}

/// Video picked from Photos, copied into the studio folder so the draft still has it later.
private struct StudioVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = StudioProject.folder.appendingPathComponent("clip-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return StudioVideoFile(url: copy)
        }
    }
}

/// Player picture with the lyric layers on top, both on the player item's clock.
private struct StudioPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let overlay: CALayer?

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var sync: AVSynchronizedLayer?
        weak var shown: CALayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            fit()
        }

        /// The overlay is built `renderSize` big; it is scaled down to the view here, so the
        /// preview wraps and places words exactly as the export does.
        func fit() {
            guard let sync, let shown else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sync.frame = bounds
            let scale = bounds.width / StudioComposer.renderSize.width
            shown.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            shown.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }

    func makeUIView(context _: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerView, context _: Context) {
        view.playerLayer.player = player
        guard view.shown !== overlay else { return }
        view.sync?.removeFromSuperlayer()
        view.sync = nil
        guard let overlay, let item = player.currentItem else { return }
        let sync = AVSynchronizedLayer(playerItem: item)
        sync.addSublayer(overlay)
        view.layer.addSublayer(sync)
        view.sync = sync
        view.shown = overlay
        view.fit()
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
