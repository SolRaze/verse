import XCTest
@testable import Verse

/// Library's root layout (#14) is edited in place now, sharing Home's reorder maths. What's its
/// own is the catalogue and the pref parsing — the bug being fixed was an item that came back
/// broken after a remove-then-add round trip, so that round trip is the thing worth pinning.
final class LibraryLayoutTests: XCTestCase {

    func testCatalogueCoversEveryCollectionPlusTheStructuralRows() {
        let ids = Set(LibraryLayout.catalog.map(\.id))
        for kind in CollectionKind.allCases {
            XCTAssertTrue(ids.contains(kind.id), "\(kind.id) can't be added back once removed")
        }
        XCTAssertTrue(ids.contains("folders"))
        XCTAssertTrue(ids.contains("recentAdded"))
    }

    func testDefaultPrefParsesWhole() {
        let parsed = LibraryLayout.parse(Pref.librarySectionsDefault)
        XCTAssertEqual(parsed.count, Pref.librarySectionsDefault.split(separator: ",").count)
        XCTAssertEqual(LibraryLayout.csv(parsed), Pref.librarySectionsDefault)
    }

    func testParseDropsUnknownAndRepeatedIDs() {
        // An id the catalogue doesn't know renders nothing and can't be deleted, so it drops.
        XCTAssertEqual(LibraryLayout.parse("songs,ghost,songs, albums "), ["songs", "albums"])
        XCTAssertEqual(LibraryLayout.parse(""), [])
    }

    func testRemoveThenAddRestoresAWorkingRow() {
        var ids = LibraryLayout.parse(Pref.librarySectionsDefault)
        ids.removeAll { $0 == "albums" }
        XCTAssertFalse(ids.contains("albums"))
        // Re-added at the end, exactly once, and still parseable — the old editor left a row that
        // had lost its remove action after this round trip.
        ids.append("albums")
        let round = LibraryLayout.parse(LibraryLayout.csv(ids))
        XCTAssertEqual(round.filter { $0 == "albums" }.count, 1)
        XCTAssertEqual(round.last, "albums")
        XCTAssertEqual(Set(round), Set(LibraryLayout.parse(Pref.librarySectionsDefault)))
    }

    func testReorderUsesHomesRule() {
        let ids = ["songs", "albums", "artists"]
        XCTAssertEqual(HomeLayout.move(ids, "artists", before: "songs"),
                       ["artists", "songs", "albums"])
    }
}
