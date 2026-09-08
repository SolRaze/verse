import XCTest
@testable import Verse

/// Home's status tile (#5) counts what the review list would show. The counting is what these
/// cover — the store's `reviewState` already has its own behaviour elsewhere.
final class FetchTallyTests: XCTestCase {

    func testCountsPerState() {
        let tally = FetchTally(states: [.missing, .missing, .found, .conflict, .ignored])
        XCTAssertEqual(tally.missing, 2)
        XCTAssertEqual(tally.found, 1)
        XCTAssertEqual(tally.conflict, 1)
        XCTAssertEqual(tally.ignored, 1)
        XCTAssertEqual(tally.total, 5)
        XCTAssertEqual(tally.count(.missing), 2)
    }

    func testIgnoredIsNotAttention() {
        // "Ignored" is a decision the user already made, so it must not read as work waiting.
        let tally = FetchTally(states: [.ignored, .ignored, .found])
        XCTAssertEqual(tally.attention, 0)
        XCTAssertEqual(tally.headline, "All set")
    }

    func testHeadlineCountsConflictsAndGaps() {
        XCTAssertEqual(FetchTally(states: [.missing, .conflict]).attention, 2)
        XCTAssertEqual(FetchTally(states: [.missing, .conflict]).headline, "2 need attention")
        XCTAssertEqual(FetchTally(states: [.missing]).headline, "1 needs attention")
    }

    func testEmptyLibraryHasNothingToFetch() {
        XCTAssertEqual(FetchTally(states: []).headline, "Nothing to fetch")
        XCTAssertEqual(FetchTally(states: []).total, 0)
    }
}
