import XCTest
@testable import Verse

/// The Info page edits in place now (#11), so the freeze rule it shares with `EditItemSheet` and
/// the lyric kind it displays both have to hold on their own.
final class InfoEditTests: XCTestCase {

    // `DeveloperToolsSupport` exports a `LibraryItem` too, so the name has to be qualified here.
    private func track() -> Verse.LibraryItem {
        var item = Verse.LibraryItem(title: "Song", artist: "Nobody",
                                     source: .file(bookmark: Data()), isVideo: false)
        item.album = "Record"
        item.trackNumber = 3
        return item
    }

    func testOnlyChangedFieldsFreeze() {
        let was = track()
        var edited = was
        edited.title = "Song (Remaster)"
        edited.freezeEdits(from: was)
        // Title was retyped, so it stops taking online metadata; artist and album were not
        // touched and must stay fetchable.
        XCTAssertTrue(edited.isFrozen(.title))
        XCTAssertFalse(edited.isFrozen(.artist))
        XCTAssertFalse(edited.isFrozen(.album))
        XCTAssertFalse(edited.isFrozen(.trackNumber))
    }

    func testClearingANumberFreezesIt() {
        let was = track()
        var edited = was
        edited.trackNumber = nil        // blank field means "no number", and that is an edit
        edited.freezeEdits(from: was)
        XCTAssertTrue(edited.isFrozen(.trackNumber))
        XCTAssertFalse(edited.isFrozen(.discNumber))
    }

    func testSavingWithNoChangesFreezesNothing() {
        let was = track()
        var edited = was
        edited.freezeEdits(from: was)
        XCTAssertTrue(edited.frozenFields.isEmpty)
    }

    func testUnlockSurvivesSave() {
        var was = track()
        was.frozenFields.insert(MetaField.album.rawValue)
        var edited = was
        edited.frozenFields.remove(MetaField.album.rawValue)   // the Unlock button
        edited.freezeEdits(from: was)
        // Unlocking without retyping the field must not re-freeze it — freezeEdits only inserts.
        XCTAssertFalse(edited.isFrozen(.album))
    }

    func testLyricsKindReadsTheCache() {
        let synced = UUID().uuidString, plain = UUID().uuidString, miss = UUID().uuidString
        LyricsResolver.attach(lrcText: "[00:01.00]first\n[00:05.00]second", cacheKey: synced)
        LyricsResolver.attach(lrcText: "no timestamps here", cacheKey: plain)
        LyricsResolver.attach(lrcText: "", cacheKey: miss)     // the resolver's negative cache
        XCTAssertEqual(LyricsResolver.cachedKind(for: synced), .synced)
        XCTAssertEqual(LyricsResolver.cachedKind(for: plain), .plain)
        XCTAssertEqual(LyricsResolver.cachedKind(for: miss), .none)
        XCTAssertEqual(LyricsResolver.cachedKind(for: UUID().uuidString), .unfetched)
    }
}
