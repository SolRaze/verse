import XCTest
@testable import Verse

/// Placeholder text only — the parser doesn't care what the words are.
final class LyricsTests: XCTestCase {

    func testParsesTimestampFormats() {
        let lrc = """
        [ti:Placeholder]
        [ar:Nobody]
        [00:01.5]line one
        [00:12.25]line two
        [01:05.500]line three
        [10:00]line four
        """
        let l = LRCParser.parse(lrc)
        XCTAssertTrue(l.isSynced)
        XCTAssertEqual(l.lines.map(\.time), [1.5, 12.25, 65.5, 600])
        XCTAssertEqual(l.lines.map(\.text), ["line one", "line two", "line three", "line four"])
    }

    func testRepeatedTimestampsOnOneLine() {
        let l = LRCParser.parse("[00:10.00][00:40.00]chorus")
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines.map(\.time), [10, 40])
        XCTAssertTrue(l.lines.allSatisfy { $0.text == "chorus" })
    }

    func testSortsOutOfOrderAndSkipsBlanks() {
        let l = LRCParser.parse("[00:30.00]second\n\n[00:10.00]first\n")
        XCTAssertEqual(l.lines.map(\.text), ["first", "second"])
    }

    func testOffsetShiftsLookup() {
        // +500ms means lyrics should appear half a second earlier.
        let l = LRCParser.parse("[offset:+500]\n[00:10.00]a")
        XCTAssertEqual(l.offset, -0.5)
        XCTAssertNil(l.lineIndex(at: 9.0))
        XCTAssertEqual(l.lineIndex(at: 9.6), 0)
    }

    func testPlainTextWhenNoTimestamps() {
        let l = LRCParser.parse("just some words\nand more")
        XCTAssertFalse(l.isSynced)
        XCTAssertEqual(l.plain, "just some words\nand more")
    }

    /// Issue #4: an empty cache file is a remembered miss — resolve must return nil from disk
    /// without touching the network (a sidecar/LRCLIB hit would prove the cache was skipped).
    func testEmptyCacheFileIsANegativeHit() async {
        let key = "negative-\(UUID().uuidString)"
        LyricsResolver.attach(lrcText: "", cacheKey: key)
        let resolved = await LyricsResolver.resolve(
            mediaURL: nil, title: "Bohemian Rhapsody", artist: "Queen",
            duration: 355, cacheKey: key)
        XCTAssertNil(resolved, "cached miss must short-circuit, not re-resolve a famous track")
    }

    func testLineIndexBoundaries() {
        let l = LRCParser.parse("[00:10.00]a\n[00:20.00]b")
        XCTAssertNil(l.lineIndex(at: 0))          // before the first line
        XCTAssertNil(l.lineIndex(at: 9.99))
        XCTAssertEqual(l.lineIndex(at: 10.0), 0)  // exactly on a timestamp
        XCTAssertEqual(l.lineIndex(at: 19.99), 0)
        XCTAssertEqual(l.lineIndex(at: 20.0), 1)
        XCTAssertEqual(l.lineIndex(at: 9_999), 1) // past the last line, stays on it
    }
}
