import UIKit
import XCTest
@testable import Verse

/// The strip is six slots and no more (#9), and every icon it can hold has to actually resolve
/// (#18) — a symbol name with no `.fill` variant renders blank the moment the track is liked.
final class ReactionTests: XCTestCase {

    func testEveryLibraryGlyphAndItsFillResolve() {
        for glyph in Pref.likeGlyphs {
            XCTAssertNotNil(UIImage(systemName: glyph), "\(glyph) is not an SF Symbol")
            XCTAssertNotNil(UIImage(systemName: "\(glyph).fill"), "\(glyph) has no .fill variant")
        }
    }

    func testDefaultsAreInTheLibrary() {
        for glyph in ReactionSlots.defaults {
            XCTAssertTrue(Pref.likeGlyphs.contains(glyph), "\(glyph) is not browsable")
        }
    }

    func testParseAlwaysYieldsSixDistinctSlots() {
        XCTAssertEqual(ReactionSlots.parse("").count, ReactionSlots.max)
        XCTAssertEqual(ReactionSlots.parse("heart,heart, ,star").count, ReactionSlots.max)
        // A short or dirty pref tops up from the defaults instead of leaving a gap.
        XCTAssertEqual(ReactionSlots.parse("moon,leaf").prefix(2).map { $0 }, ["moon", "leaf"])
        XCTAssertEqual(Set(ReactionSlots.parse("heart,heart,star")).count, ReactionSlots.max)
        // Over-long input is cut, not appended to.
        XCTAssertEqual(ReactionSlots.parse("a,b,c,d,e,f,g,h"), ["a", "b", "c", "d", "e", "f"])
    }

    func testReplacingSwapsInsteadOfDuplicating() {
        let slots = ["heart", "star", "flame", "bolt", "crown", "face.smiling"]
        // Fresh glyph: straight replacement.
        XCTAssertEqual(ReactionSlots.replacing(slots, at: 2, with: "moon")[2], "moon")
        XCTAssertEqual(ReactionSlots.replacing(slots, at: 2, with: "moon").count, ReactionSlots.max)
        // Glyph already in the strip: the two slots trade, so no duplicate appears.
        let swapped = ReactionSlots.replacing(slots, at: 0, with: "crown")
        XCTAssertEqual(swapped[0], "crown")
        XCTAssertEqual(swapped[4], "heart")
        XCTAssertEqual(Set(swapped).count, ReactionSlots.max)
        // Out-of-range index is a no-op, not a crash.
        XCTAssertEqual(ReactionSlots.replacing(slots, at: 9, with: "moon"), slots)
    }

    func testRecentsAreNewestFirstDedupedAndCapped() {
        var csv = ""
        for glyph in ["heart", "star", "moon", "heart"] {
            csv = ReactionSlots.pushRecent(glyph, into: csv)
        }
        XCTAssertEqual(ReactionSlots.recents(csv), ["heart", "moon", "star"])

        var long = ""
        for glyph in Pref.likeGlyphs { long = ReactionSlots.pushRecent(glyph, into: long) }
        XCTAssertEqual(ReactionSlots.recents(long).count, ReactionSlots.recentsCap)
        XCTAssertEqual(ReactionSlots.recents(long).first, Pref.likeGlyphs.last)
    }

    func testSearchMatchesDottedNamesByWords() {
        XCTAssertEqual(ReactionSlots.search(""), Pref.likeGlyphs)
        XCTAssertTrue(ReactionSlots.search("thumbs").contains("hand.thumbsup"))
        // The dot has to read as a space or "hand thumbsup" would never match.
        XCTAssertTrue(ReactionSlots.search("hand thumbs").contains("hand.thumbsup"))
        XCTAssertTrue(ReactionSlots.search("HEART").contains("heart"))
        XCTAssertTrue(ReactionSlots.search("zzzz").isEmpty)
    }
}
