import XCTest
@testable import Verse

/// Home is two zones now (#2/#3/#4): a 4-column tile grid and a stack of full-width shelves, each
/// with its own pref. The maths that keeps them apart is what these cover — the gestures on top
/// are device-only.
final class HomeLayoutTests: XCTestCase {

    func testTilePrefRoundTrips() {
        // Both sizes have to be ones their item actually offers, or parsing snaps them away.
        let tiles = [HomeTile(id: "now", cols: 2, rows: 1), HomeTile(id: "albums", cols: 2, rows: 2)]
        XCTAssertEqual(HomeLayout.parseTiles(HomeLayout.tilesCSV(tiles)), tiles)
    }

    func testTileParseDropsJunk() {
        // A shelf id, a repeat, and a span nothing offers — none of them may reach the grid.
        let parsed = HomeLayout.parseTiles("now:2:2,tracks:1:1,now:1:1,albums:9:9")
        XCTAssertEqual(parsed.map(\.id), ["now", "albums"])
        // 9x9 snaps to the largest preset rather than blowing past the 4-column grid.
        XCTAssertEqual(parsed.last?.cols, 2)
        XCTAssertEqual(parsed.last?.rows, 2)
    }

    func testEachItemSnapsWithinItsOwnPresets() {
        // Now Playing has no 1x1 — a title needs two cells — so a bare id lands on its smallest.
        XCTAssertEqual(HomeLayout.parseTiles("now"), [HomeTile(id: "now", cols: 2, rows: 1)])
        // Albums skips the wide-short size, which would crush its square covers.
        XCTAssertEqual(HomeLayout.parseTiles("albums:2:1"), [HomeTile(id: "albums", cols: 1, rows: 1)])
        // Anything without its own list keeps all three.
        XCTAssertEqual(HomeLayout.parseTiles("fetch:2:1"), [HomeTile(id: "fetch", cols: 2, rows: 1)])
    }

    func testShelfParseDropsTileIDs() {
        // "now" is tile-only; leaving it in the shelf pref would render it twice.
        XCTAssertEqual(HomeLayout.parseShelves("playlists,now,tracks,playlists"),
                       ["playlists", "tracks"])
    }

    func testMigrationSplitsTheOldSingleList() {
        let moved = HomeLayout.migrate(sectionsCSV: "now,playlists,albums,tracks", tilesCSV: nil)
        XCTAssertEqual(moved.tiles, "now:2:2,albums:2:2")
        XCTAssertEqual(moved.shelves, "playlists,tracks")
    }

    func testMigrationLeavesAWrittenLayoutAlone() {
        let moved = HomeLayout.migrate(sectionsCSV: "playlists,tracks", tilesCSV: "now:1:1")
        XCTAssertEqual(moved.tiles, "now:1:1")
        XCTAssertEqual(moved.shelves, "playlists,tracks")
    }

    func testMigrationWithNoTileIDsFallsBackToTheDefault() {
        let moved = HomeLayout.migrate(sectionsCSV: "playlists,tracks", tilesCSV: nil)
        XCTAssertEqual(moved.tiles, HomeLayout.defaultTilesCSV)
    }

    func testResizeSnapsToTheNearestPreset() {
        // A small drag off a 1x1 lands on the pill, not somewhere between two sizes.
        XCTAssertTrue(HomeLayout.snap(cols: 2, rows: 1, for: "fetch") == (2, 1))
        XCTAssertTrue(HomeLayout.snap(cols: 3, rows: 3, for: "fetch") == (2, 2))
        XCTAssertTrue(HomeLayout.snap(cols: 0, rows: 0, for: "fetch") == (1, 1))
        // An item with its own preset list can never be dragged to a size outside it.
        XCTAssertTrue(HomeLayout.snap(cols: 1, rows: 1, for: "now") == (2, 1))
        XCTAssertTrue(HomeLayout.snap(cols: 2, rows: 1, for: "albums") == (1, 1))
    }

    func testMoveInsertsBeforeTheDropTarget() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(HomeLayout.move(ids, "c", before: "a"), ["c", "a", "b"])
        // Dragged item takes the target's slot and pushes it right, so a forward move lands
        // before the thing it was dropped on, not after it.
        XCTAssertEqual(HomeLayout.move(ids, "a", before: "c"), ["b", "a", "c"])
        // Dropping something on itself, or dropping an id that isn't in the zone, changes nothing.
        XCTAssertEqual(HomeLayout.move(ids, "a", before: "a"), ids)
        XCTAssertEqual(HomeLayout.move(ids, "z", before: "a"), ids)
    }

    func testPackingWrapsAtFourColumns() {
        let wide = HomeTile(id: "now", cols: 2, rows: 2)
        let narrow = HomeTile(id: "albums", cols: 1, rows: 1)
        XCTAssertEqual(HomeLayout.pack([wide, wide]).count, 1)          // 2 + 2 = one full row
        XCTAssertEqual(HomeLayout.pack([wide, wide, narrow]).count, 2)  // the third wraps
        XCTAssertEqual(HomeLayout.pack([]).count, 0)
    }
}
