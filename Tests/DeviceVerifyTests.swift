import ActivityKit
import AVFoundation
import XCTest
@testable import Verse

/// On-device integration checks for the three unverified pillars: VLC playback, lyrics
/// resolution over the network, and YouTube extraction. These hit real services and real
/// hardware — run them on the phone, not in CI.
final class DeviceVerifyTests: XCTestCase {

    // MARK: VLC playback

    @MainActor
    func testVLCPlaysLocalAudio() async throws {
        let player = Player()
        try player.activateAudioSession()
        player.load(.init(url: try makeWAV(), title: "Tone", artist: "Test"), lyrics: nil)

        let start = Date()
        while player.position < 0.5 {
            if Date().timeIntervalSince(start) > 10 {
                return XCTFail("VLC position stuck at \(player.position), isPlaying=\(player.isPlaying), state should be advancing")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.duration, 4, "5s tone should report ~5s duration")
        player.stop()
    }

    // MARK: Lyrics via LRCLIB

    func testLRCLIBReturnsSyncedLyrics() async throws {
        let lyrics = try await LRCLibClient().fetch(
            .init(track: "Bohemian Rhapsody", artist: "Queen", duration: 355))
        let l = try XCTUnwrap(lyrics, "LRCLIB returned nothing — network filter or API change")
        XCTAssertTrue(l.isSynced, "expected synced lyrics for a famous track")
        XCTAssertGreaterThan(l.lines.count, 20)
    }

    // MARK: YouTube extraction + the AVPlayer path that actually plays it

    func testYouTubeExtractsAndAVPlayerLoads() async throws {
        // "Me at the zoo" — 19s, oldest video on YouTube, effectively never taken down.
        let ex = try await YouTubeSource.extract(
            watchURL: URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!,
            audioOnly: false)
        XCTAssertFalse(ex.title.isEmpty)

        let item = AVPlayerItem(url: ex.streamURL)
        let ready = expectation(description: "stream reaches readyToPlay")
        let obs = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay { ready.fulfill() }
            if item.status == .failed {
                XCTFail("AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
                ready.fulfill()
            }
        }
        let player = AVPlayer(playerItem: item)
        player.play()
        await fulfillment(of: [ready], timeout: 30)
        obs.invalidate()
        player.pause()
    }

    // MARK: Embedded cover art → thumbnail cache

    func testArtworkExtractsEmbeddedCover() async throws {
        // Build a tiny m4a with an embedded artwork atom via AVAssetWriter would be heavy;
        // instead assert the negative-and-positive contract on a real file. A generated WAV has
        // no cover, so store() must leave the cache empty (no false thumbnail).
        let wav = try makeWAV()
        let key = UUID().uuidString
        await Artwork.store(from: wav, key: key)
        XCTAssertNil(Artwork.image(for: key), "no embedded art → no thumbnail, not a blank one")
        // Issue #4: the miss leaves a marker so the next play skips the AVAsset load entirely;
        // invalidate (manual Fetch Metadata) clears it for a real retry.
        XCTAssertTrue(Artwork.exists(for: key), "miss must be remembered, not retried every play")
        Artwork.invalidate(key: key)
        XCTAssertFalse(Artwork.exists(for: key))

        // Positive path: hand-write a jpeg into the cache location the way import does, confirm
        // the memory+disk read round-trips.
        let key2 = UUID().uuidString
        let img = UIGraphicsImageRenderer(size: .init(width: 10, height: 10)).image { ctx in
            UIColor.red.setFill(); ctx.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try img.jpegData(compressionQuality: 0.8)!.write(to: dir.appendingPathComponent(key2 + ".jpg"))
        XCTAssertTrue(Artwork.exists(for: key2))
        XCTAssertNotNil(Artwork.image(for: key2))

        // Rows draw at 28–44pt, so they read a derived small copy instead of decoding the 600px
        // file. invalidate has to clear both tiers, or a refetched cover keeps showing the stale
        // row-sized one long after the big one was replaced.
        XCTAssertNotNil(Artwork.thumb(for: key2), "thumb derives from the full-size file")
        Artwork.invalidate(key: key2)
        XCTAssertNil(Artwork.thumb(for: key2), "invalidate must clear the row-sized copy too")
    }

    // MARK: Waveform decode + disk cache

    func testWaveformDecodesAndCaches() async throws {
        let wav = try makeWAV()
        let firstLoad = await Waveform.load(url: wav)
        let first = try XCTUnwrap(firstLoad, "WAV is AVFoundation-decodable")
        XCTAssertEqual(first.count, 120)
        XCTAssertEqual(first.max(), 1, "buckets normalize to peak 1")
        let secondLoad = await Waveform.load(url: wav)
        XCTAssertEqual(first, secondLoad, "cache round-trip returns identical buckets")
    }

    // MARK: Folder import preserves the tree

    @MainActor
    func testFolderImportBuildsTree() throws {
        // Music/Rock/Album/a.mp3, Music/Rock/b.mp3, Music/c.mp3
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Music-\(UUID().uuidString)")
        let rockAlbum = root.appendingPathComponent("Rock/Album")
        try FileManager.default.createDirectory(at: rockAlbum, withIntermediateDirectories: true)
        let wav = try makeWAV()
        try Data(contentsOf: wav).write(to: rockAlbum.appendingPathComponent("a.mp3"))
        try Data(contentsOf: wav).write(to: root.appendingPathComponent("Rock/b.mp3"))
        try Data(contentsOf: wav).write(to: root.appendingPathComponent("c.mp3"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore()
        let rootName = root.lastPathComponent
        store.add(pickedURLs: [root])

        XCTAssertEqual(store.descendants(of: [rootName]).count, 3, "all three files imported")

        let top = store.children(of: [rootName])
        XCTAssertEqual(top.folders, ["Rock"], "one subfolder at top")
        XCTAssertEqual(top.items.map(\.title), ["c"], "loose file c sits at root")

        let rock = store.children(of: [rootName, "Rock"])
        XCTAssertEqual(rock.folders, ["Album"])
        XCTAssertEqual(rock.items.map(\.title), ["b"])

        let album = store.children(of: [rootName, "Rock", "Album"])
        XCTAssertEqual(album.items.map(\.title), ["a"])

        store.removeFolder([rootName, "Rock"])
        XCTAssertEqual(store.descendants(of: [rootName]).count, 1, "subtree delete leaves only c")
    }

    // MARK: Folder create + move management

    @MainActor
    func testCreateFolderAndMoveItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: try makeWAV()).write(to: root.appendingPathComponent("song.mp3"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore()
        store.add(pickedURLs: [root])
        let rootName = root.lastPathComponent
        // Unique name — LibraryStore persists to shared Documents, so a fixed name would
        // accumulate across runs.
        let dest = "Fav-\(UUID().uuidString)"
        defer { store.removeFolder([dest]); store.removeFolder([rootName]); store.flush() }

        // Empty custom folder shows even with no items in it.
        store.createFolder(named: dest, in: [])
        XCTAssertTrue(store.children(of: []).folders.contains(dest))

        // Move the imported song into it.
        let song = try XCTUnwrap(store.descendants(of: [rootName]).first)
        store.move(song, to: [dest])
        XCTAssertEqual(store.children(of: [dest]).items.map(\.title), ["song"])
        XCTAssertTrue(store.descendants(of: [rootName]).isEmpty, "moved out of its import folder")
        XCTAssertTrue(store.allFolders().contains([dest]))
    }

    /// Library writes are coalesced now, so durability hangs on `flush()`: whatever the last
    /// mutation was, flushing has to make it survive into a freshly constructed store. This is
    /// the check that fails if the debounce ever stops being cancelled properly.
    @MainActor
    func testFlushMakesTheLastMutationDurable() {
        let store = LibraryStore()
        // Unique name — LibraryStore persists to shared Documents, so a fixed one would
        // accumulate across runs.
        let name = "Flush-\(UUID().uuidString)"
        defer { store.removeFolder([name]); store.flush() }

        store.createFolder(named: name, in: [])
        store.flush()

        XCTAssertTrue(LibraryStore().allFolders().contains([name]),
                      "flush must land the coalesced write before the app can be killed")
    }

    // MARK: Play counts -> Home's shelves

    @MainActor
    func testPlayCountsRankHomeShelves() throws {
        // Two albums under one root: A/ (a1, a2), B/ (b1).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Play-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let wav = try makeWAV()
        try Data(contentsOf: wav).write(to: a.appendingPathComponent("a1.mp3"))
        try Data(contentsOf: wav).write(to: a.appendingPathComponent("a2.mp3"))
        try Data(contentsOf: wav).write(to: b.appendingPathComponent("b1.mp3"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore()
        let rootName = root.lastPathComponent
        store.add(pickedURLs: [root])
        defer { store.removeFolder([rootName]); store.flush() }

        // Scoped to this test's own items — the store persists to shared Documents, so anything
        // a previous run left behind would otherwise show up in these rankings.
        // Qualified: DeveloperToolsSupport exports its own `LibraryItem`, so the bare name is
        // ambiguous in type position.
        func myTracks() -> [Verse.LibraryItem] {
            store.mostPlayedTracks(limit: 50).filter { $0.folders.first == rootName }
        }
        // Albums are metadata-keyed now (albumKey: tag, else containing folder name) — scope
        // to albums whose tracks live under this test's unique root.
        func myAlbums() -> [(name: String, plays: Int)] {
            store.mostPlayedAlbums(limit: 50).filter { a in
                store.items.contains { $0.folders.first == rootName && $0.albumKey == a.name }
            }
        }

        XCTAssertTrue(myTracks().isEmpty, "nothing played yet")
        XCTAssertTrue(myAlbums().isEmpty, "no album ranks before a play")

        let a1 = try XCTUnwrap(store.children(of: [rootName, "A"]).items.first { $0.title == "a1" })
        let b1 = try XCTUnwrap(store.children(of: [rootName, "B"]).items.first { $0.title == "b1" })
        store.recordPlay(b1)
        store.recordPlay(a1)
        store.recordPlay(a1)

        XCTAssertEqual(myTracks().map(\.title), ["a1", "b1"], "ranked by play count, descending")
        XCTAssertEqual(myTracks().first?.playCount, 2)
        XCTAssertNotNil(myTracks().first?.lastPlayed)

        // A (2 plays) outranks B (1). The import root holds no tracks directly, so it must not
        // rank — otherwise every play would count twice, once for the album and once for its parent.
        XCTAssertEqual(myAlbums().map(\.name), ["A", "B"])
        XCTAssertEqual(myAlbums().first?.plays, 2)
        XCTAssertFalse(myAlbums().contains { $0.name == rootName }, "parent folder must not rank")

        // Remote playlist entries are synthesised per play and were never stored — counting one
        // must be a no-op, not a crash.
        store.recordPlay(LibraryItem(title: "ghost", artist: "",
                                     source: .youtube(watchURL: URL(string: "https://y/x")!),
                                     isVideo: false))
        XCTAssertEqual(myTracks().count, 2, "an unknown item doesn't enter the library")
    }

    // MARK: Shuffle + repeat mode

    @MainActor
    func testRepeatModeCycles() {
        let store = LibraryStore()
        let c = Coordinator(library: store)
        XCTAssertEqual(c.repeatMode, .off)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .all)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .one)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .off)
    }

    @MainActor
    func testShufflePreservesCurrentAndRestores() {
        let store = LibraryStore()
        let c = Coordinator(library: store)
        let items = (0..<8).map { LibraryItem(title: "t\($0)", artist: "", source: .youtube(watchURL: URL(string: "https://y/\($0)")!), isVideo: false) }
        c.play(items[3], in: items)
        XCTAssertEqual(c.nowPlayingItemID, items[3].id)

        c.toggleShuffle()
        XCTAssertTrue(c.isShuffled)
        XCTAssertEqual(c.nowPlayingItemID, items[3].id, "current track stays put when shuffling")

        c.toggleShuffle()
        XCTAssertFalse(c.isShuffled)
        XCTAssertEqual(c.nowPlayingItemID, items[3].id, "original order restored, still on the same track")
    }

    // MARK: File-manager ops — rename, move folder, batch, sort

    @MainActor
    func testFolderRenameMoveBatchSort() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fm-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let wav = try makeWAV()
        try Data(contentsOf: wav).write(to: sub.appendingPathComponent("b song.mp3"))
        try Data(contentsOf: wav).write(to: sub.appendingPathComponent("a song.mp3"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore()
        store.add(pickedURLs: [root])
        let rootName = root.lastPathComponent
        defer { store.removeFolder([rootName]); store.flush() }

        // Sort by name ascending/descending.
        store.sortField = .name; store.sortAscending = true
        XCTAssertEqual(store.children(of: [rootName, "A"]).items.map(\.title), ["a song", "b song"])
        store.sortAscending = false
        XCTAssertEqual(store.children(of: [rootName, "A"]).items.map(\.title), ["b song", "a song"])

        // Rename folder A -> Alpha; items follow.
        store.renameFolder([rootName, "A"], to: "Alpha")
        XCTAssertEqual(store.descendants(of: [rootName, "Alpha"]).count, 2)
        XCTAssertTrue(store.descendants(of: [rootName, "A"]).isEmpty)

        // Move Alpha under a new top folder.
        store.createFolder(named: "Top-\(rootName)", in: [])
        store.moveFolder([rootName, "Alpha"], under: ["Top-\(rootName)"])
        XCTAssertEqual(store.descendants(of: ["Top-\(rootName)", "Alpha"]).count, 2)
        defer { store.removeFolder(["Top-\(rootName)"]); store.flush() }

        // Batch move both items to root, then batch delete.
        let ids = Set(store.descendants(of: ["Top-\(rootName)", "Alpha"]).map(\.id))
        store.move(ids, to: [])
        XCTAssertEqual(store.children(of: []).items.filter { ids.contains($0.id) }.count, 2)
        store.remove(ids)
        XCTAssertTrue(store.items.filter { ids.contains($0.id) }.isEmpty)
    }

    // MARK: Playlist fetchers (live scrapes — these break when the sites change)

    func testYouTubePlaylistFetch() async throws {
        // "Pop Hits" — public, huge, years old.
        let pl = try await PlaylistFetcher.fetch(
            url: URL(string: "https://www.youtube.com/playlist?list=PLMC9KNkIncKtPzgY-5rmhvj7fax8fdxoj")!)
        XCTAssertEqual(pl.kind, .youtubePlaylist)
        XCTAssertGreaterThan(pl.entries.count, 10)
        XCTAssertNotNil(pl.entries.first?.watchURL)
    }

    func testSpotifyPlaylistFetch() async throws {
        // "Today's Top Hits" — Spotify-owned, not going anywhere.
        let pl = try await PlaylistFetcher.fetch(
            url: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
        XCTAssertEqual(pl.kind, .spotify)
        XCTAssertGreaterThan(pl.entries.count, 10)
        XCTAssertFalse(pl.entries[0].title.isEmpty)
    }

    func testSoundCloudSetFetch() async throws {
        // Flume's "Skin" album set — public, stable.
        let pl = try await PlaylistFetcher.fetch(
            url: URL(string: "https://soundcloud.com/flume/sets/skin")!)
        XCTAssertEqual(pl.kind, .soundcloud)
        XCTAssertGreaterThan(pl.entries.count, 3)
        XCTAssertFalse(pl.entries[0].title.isEmpty)
    }

    func testYouTubeSearchFindsVideo() async throws {
        let url = try await PlaylistFetcher.youtubeSearch("me at the zoo")
        XCTAssertTrue(url.absoluteString.contains("watch?v="))
    }

    // MARK: Live Activity follows lyric lines

    @MainActor
    func testLiveActivityTracksLyricLines() async throws {
        try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled,
                          "Live Activities disabled in Settings")
        let player = Player()
        try player.activateAudioSession()
        let lyrics = LRCParser.parse("[00:00.50]alpha\n[00:01.50]beta\n[00:03.80]gamma")
        player.load(.init(url: try makeWAV(), title: "Tone", artist: "Test"), lyrics: lyrics)

        var start = Date()
        while player.position < 2.0 {
            if Date().timeIntervalSince(start) > 15 { return XCTFail("playback stalled") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let activity = try XCTUnwrap(
            Activity<LyricActivityAttributes>.activities.first, "no Live Activity started")
        start = Date()
        while activity.content.state.current != "beta" {
            if Date().timeIntervalSince(start) > 5 {
                return XCTFail("activity stuck on '\(activity.content.state.current)', expected 'beta'")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(activity.content.state.previous, "alpha")

        player.stop()
        start = Date()
        while !Activity<LyricActivityAttributes>.activities.isEmpty {
            if Date().timeIntervalSince(start) > 5 { return XCTFail("activity not ended on stop") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: -

    /// Minimal PCM16 mono WAV, 5s of 440Hz — no bundled asset needed.
    private func makeWAV() throws -> URL {
        let sampleRate = 8000, seconds = 5, n = sampleRate * seconds
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + n * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(n * 2))
        for i in 0..<n {
            u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / Double(sampleRate)) * 8000)))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone.wav")
        try data.write(to: url)
        return url
    }
}
