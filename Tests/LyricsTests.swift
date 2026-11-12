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

    // MARK: word timing

    func testEnhancedLRCParsesWordsAndStripsTags() {
        let l = LRCParser.parse("[00:12.88]<00:12.88>one <00:13.18>two <00:13.50>three\n[00:24.43]<00:24.43>four <00:24.72>five<00:26.00>")
        XCTAssertEqual(l.lines.map(\.text), ["one two three", "four five"])
        XCTAssertEqual(l.lines[0].words.map(\.text), ["one ", "two ", "three"])
        XCTAssertEqual(l.lines[0].words[1].time, 13.18, accuracy: 0.001)
        XCTAssertEqual(l.lines[1].words.count, 2)   // trailing tag marks the line end, no word
        XCTAssertTrue(l.hasWordTiming)
        XCTAssertEqual(l.wordIndex(in: l.lines[0].words, at: 13.3), 1)
        XCTAssertNil(l.wordIndex(in: l.lines[0].words, at: 1))
    }

    func testWordTimingRoundTripsThroughLRCText() {
        let l = LRCParser.parse("[00:12.88]<00:12.88>one <00:13.18>two\n[00:30.00]plain line")
        XCTAssertEqual(LRCParser.parse(l.lrcText!), l)
    }

    func testEstimatedWordsStayInsideTheLine() {
        let l = LRCParser.parse("[00:30.00]short longerword end\n[00:33.00]next\n[01:30.00]after a gap")
        let w = l.words(forLine: 0)
        XCTAssertEqual(w.map(\.text), ["short ", "longerword ", "end"])
        XCTAssertEqual(w[0].time, 30)
        XCTAssertTrue(w[1].time > w[0].time && w[2].time > w[1].time && w[2].time < 33)
        // A line before a long gap spreads over the cap, not the gap.
        XCTAssertLessThan(l.words(forLine: 1)[0].time + Lyrics.maxLineSpan, 90)
        XCTAssertLessThanOrEqual(l.words(forLine: 2).last!.time, 90 + Lyrics.maxLineSpan)
    }

    func testNetEaseYRCConvertsToEnhancedLRC() {
        let yrc = """
        {"t":0,"c":[{"tx":"credit"}]}
        [390,2400](390,390,0)one (780,210,0)two(990,0,0), (990,390,0)three
        [2790,2160](2790,510,0)(bracketed)
        """
        let l = LRCParser.parse(WordLyricsClient.enhancedLRC(fromYRC: yrc)!)
        XCTAssertEqual(l.lines.map(\.text), ["one two, three", "(bracketed)"])
        XCTAssertEqual(l.lines[0].words[1].time, 0.78, accuracy: 0.011)
        XCTAssertNil(WordLyricsClient.enhancedLRC(fromYRC: "{\"t\":0}"))
    }

    func testWordResultFromAnotherCutIsRejected() {
        let held = LRCParser.parse("[00:00.40]one two\n[00:02.60]three")
        XCTAssertTrue(LRCParser.parse("[00:00.39]<00:00.39>one <00:00.78>two").sameCut(as: held))
        XCTAssertFalse(LRCParser.parse("[00:19.65]<00:19.65>one <00:19.86>two").sameCut(as: held))
        XCTAssertTrue(LRCParser.parse("[00:19.65]<00:19.65>one").sameCut(as: nil))
    }

    func testUntaggedLeadIsAWordAndRepeatedLinesDropWordTags() {
        let lead = LRCParser.parse("[00:10.00]Hey <00:10.50>you <00:11.00>there").lines[0]
        XCTAssertEqual(lead.words.map(\.text), ["Hey ", "you ", "there"])
        XCTAssertEqual(lead.words[0].time, 10)
        // Word tags are absolute, so they cannot serve both stamps of a repeated line.
        let twice = LRCParser.parse("[00:10.00][00:40.00]<00:10.00>la <00:10.50>la")
        XCTAssertEqual(twice.lines.map(\.text), ["la la", "la la"])
        XCTAssertTrue(twice.lines.allSatisfy { $0.words.isEmpty })
    }

    func testLooseLyricsFileFindsItsTrackOnlyWhenUnambiguous() {
        let a = Verse.LibraryItem(title: "Song", artist: "Someone", source: .youtube(watchURL: URL(string: "https://example.com/a")!), isVideo: false)
        let b = Verse.LibraryItem(title: "Other", artist: "Someone", source: .youtube(watchURL: URL(string: "https://example.com/b")!), isVideo: false)
        XCTAssertEqual(Coordinator.lyricsTarget(stem: "someone - song", in: [a, b])?.id, a.id)
        XCTAssertEqual(Coordinator.lyricsTarget(stem: "OTHER", in: [a, b])?.id, b.id)
        XCTAssertNil(Coordinator.lyricsTarget(stem: "song", in: [a, a]))
        XCTAssertNil(Coordinator.lyricsTarget(stem: "missing", in: [a, b]))
        // The file's basename wins over a title that also fits.
        let names = [a.id: "01 - track", b.id: "song"]
        XCTAssertEqual(Coordinator.lyricsTarget(stem: "01 - Track", in: [a, b], basenames: names)?.id, a.id)
        XCTAssertEqual(Coordinator.lyricsTarget(stem: "Song", in: [a, b], basenames: names)?.id, b.id)
    }

    func testQueueRestoresByIDAndFollowsTheCurrentTrack() {
        func item(_ t: String) -> Verse.LibraryItem {
            Verse.LibraryItem(title: t, artist: "", source: .youtube(watchURL: URL(string: "https://example.com/\(t)")!), isVideo: false)
        }
        let a = item("a"), gone = item("gone"), c = item("c"), stream = item("stream")
        let r = Coordinator.restore(ids: [a.id, gone.id, c.id, stream.id], loose: [stream],
                                    index: 2, library: [c, a])
        XCTAssertEqual(r.queue.map(\.id), [a.id, c.id, stream.id])
        XCTAssertEqual(r.index, 1)   // still on c after the missing track dropped out
        XCTAssertTrue(Coordinator.restore(ids: [gone.id], loose: [], index: 0, library: []).queue.isEmpty)
        // Same track queued twice: back on the second copy, not the first.
        XCTAssertEqual(Coordinator.restore(ids: [a.id, c.id, a.id], loose: [], index: 2,
                                           library: [a, c]).index, 2)
    }
}
