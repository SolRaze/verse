import XCTest
@testable import Verse

/// Most-played tie-break (#6): equal play counts used to come out of a `Dictionary`, so the #1
/// album could swap between renders. Rule is plays, then most recent play, then name A→Z.
@MainActor
final class RankingTests: XCTestCase {

    // `DeveloperToolsSupport` exports a `LibraryItem` too, so the name has to be qualified here.
    private func track(_ title: String, album: String, plays: Int, last: Date?) -> Verse.LibraryItem {
        var item = Verse.LibraryItem(title: title, artist: "Nobody",
                                     source: .file(bookmark: Data()), isVideo: false)
        item.album = album
        item.playCount = plays
        item.lastPlayed = last
        return item
    }

    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    func testAlbumTieGoesToMostRecentPlay() {
        let items = [track("a", album: "Stale", plays: 3, last: older),
                     track("b", album: "Fresh", plays: 3, last: newer)]
        // Same totals, so recency decides — and it decides the same way whichever order the
        // grouping hands them back.
        XCTAssertEqual(LibraryStore.rankAlbums(items).map(\.name), ["Fresh", "Stale"])
        XCTAssertEqual(LibraryStore.rankAlbums(items.reversed()).map(\.name), ["Fresh", "Stale"])
    }

    func testAlbumTieFallsBackToNameWhenNeverPlayedAtSameCount() {
        // Equal plays and no recorded play date: name A→Z is the last resort, case-insensitive.
        let items = [track("a", album: "zeta", plays: 2, last: nil),
                     track("b", album: "Alpha", plays: 2, last: nil)]
        XCTAssertEqual(LibraryStore.rankAlbums(items).map(\.name), ["Alpha", "zeta"])
        XCTAssertEqual(LibraryStore.rankAlbums(items.reversed()).map(\.name), ["Alpha", "zeta"])
    }

    func testPlaysStillOutrankRecency() {
        let items = [track("a", album: "Played", plays: 9, last: older),
                     track("b", album: "Recent", plays: 1, last: newer)]
        XCTAssertEqual(LibraryStore.rankAlbums(items).map(\.name), ["Played", "Recent"])
    }

    func testAlbumPlaysSumAcrossTracksAndUnplayedAlbumsDrop() {
        let items = [track("a", album: "Two", plays: 1, last: older),
                     track("b", album: "Two", plays: 1, last: older),
                     track("c", album: "Never", plays: 0, last: nil)]
        XCTAssertEqual(LibraryStore.rankAlbums(items).map { [$0.name: $0.plays] }, [["Two": 2]])
    }

    func testTrackTieGoesToRecentThenTitle() {
        let items = [track("Zulu", album: "x", plays: 4, last: nil),
                     track("Alpha", album: "x", plays: 4, last: nil),
                     track("Recent", album: "x", plays: 4, last: newer)]
        XCTAssertEqual(LibraryStore.rankTracks(items).map(\.title), ["Recent", "Alpha", "Zulu"])
        XCTAssertEqual(LibraryStore.rankTracks(items.reversed()).map(\.title),
                       ["Recent", "Alpha", "Zulu"])
    }

    func testLimitCaps() {
        let items = (1...10).map { track("t\($0)", album: "a\($0)", plays: $0, last: nil) }
        XCTAssertEqual(LibraryStore.rankAlbums(items, limit: 3).count, 3)
        XCTAssertEqual(LibraryStore.rankTracks(items, limit: 3).map(\.title), ["t10", "t9", "t8"])
    }
}

/// Artist grid sectioning (#16) — "sectioned by parts" means first letter, with everything
/// non-alphabetic collected under # and # sorting last.
///
/// `@MainActor` because `CollectionPage` is a `View`, which Swift 6 isolates to the main actor —
/// its statics come with it, so calling them from a nonisolated test warns on every line.
@MainActor
final class CollectionSectionTests: XCTestCase {

    func testFirstLetterUppercased() {
        XCTAssertEqual(CollectionPage.sectionLetter(for: "aphex twin"), "A")
        XCTAssertEqual(CollectionPage.sectionLetter(for: "Zappa"), "Z")
        XCTAssertEqual(CollectionPage.sectionLetter(for: "  spaced"), "S")   // leading space
    }

    func testNonLettersBucketUnderHash() {
        XCTAssertEqual(CollectionPage.sectionLetter(for: "2Pac"), "#")
        XCTAssertEqual(CollectionPage.sectionLetter(for: "!!!"), "#")
        XCTAssertEqual(CollectionPage.sectionLetter(for: "   "), "#")   // all whitespace
        XCTAssertEqual(CollectionPage.sectionLetter(for: ""), "#")
    }

    func testHashSortsLast() {
        XCTAssertEqual(CollectionPage.sectionLettersSorted(["#", "B", "A"]), ["A", "B", "#"])
        XCTAssertEqual(CollectionPage.sectionLettersSorted(["#"]), ["#"])
        XCTAssertEqual(CollectionPage.sectionLettersSorted(["C", "A"]), ["A", "C"])
    }

    // `DeveloperToolsSupport` exports a `LibraryItem` too, so the name has to be qualified here.
    private func track(_ title: String, by artist: String) -> Verse.LibraryItem {
        Verse.LibraryItem(title: title, artist: artist,
                          source: .file(bookmark: Data()), isVideo: false)
    }

    /// The grid used to filter every item once per artist name. Collapsing that to one grouping
    /// pass has to preserve three things: which names appear, the count under each, and *which*
    /// item supplies the cover — the first in library order, not an arbitrary group member.
    func testArtistRowsKeepCountsAndTakeFirstItemAsCover() {
        let first = track("one", by: "Boards")
        let second = track("two", by: "Boards")
        let rows = CollectionPage.artistRows([first, second,
                                              track("three", by: "Aphex"),
                                              track("four", by: "")])   // untagged: no row

        XCTAssertEqual(rows.map { $0.name }, ["Aphex", "Boards"])
        XCTAssertEqual(rows.map { $0.count }, [1, 2])
        XCTAssertEqual(rows.first { $0.name == "Boards" }?.artwork?.id, first.id)
    }
}

/// Repeat button's mode machine (#12): tap cycles, hold locks repeat-one, and a locked button
/// ignores taps until the next hold.
@MainActor
final class RepeatModeTests: XCTestCase {

    private func coordinator() -> Coordinator { Coordinator(library: LibraryStore()) }

    func testTapCyclesAndWrapsToOff() {
        let c = coordinator()
        XCTAssertEqual(c.repeatMode, .off)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .all)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .one)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .off)   // three taps, back where it started
    }

    func testHoldLocksFromEveryMode() {
        for taps in 0...2 {
            let c = coordinator()
            for _ in 0..<taps { c.cycleRepeat() }
            c.toggleRepeatLock()
            XCTAssertTrue(c.repeatLocked, "hold failed to lock after \(taps) taps")
            XCTAssertEqual(c.repeatMode, .one, "lock should pin repeat-one after \(taps) taps")
        }
    }

    func testHoldAgainUnlocksToOff() {
        let c = coordinator()
        c.cycleRepeat()          // .all
        c.toggleRepeatLock()     // locked, .one
        c.toggleRepeatLock()
        XCTAssertFalse(c.repeatLocked)
        XCTAssertEqual(c.repeatMode, .off)   // unlock returns to off, not to where it was
    }

    func testTapWhileLockedDoesNothing() {
        let c = coordinator()
        c.toggleRepeatLock()
        c.cycleRepeat(); c.cycleRepeat(); c.cycleRepeat()
        XCTAssertTrue(c.repeatLocked)
        XCTAssertEqual(c.repeatMode, .one)   // the lock owns the button
    }
}
