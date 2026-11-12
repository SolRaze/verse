import XCTest
@testable import Verse

final class StudioTimelineTests: XCTestCase {
    private func clip(_ duration: Double) -> StudioClip {
        StudioClip(file: "a.mov", sourceStart: 0, duration: duration, sourceDuration: 20)
    }

    func testSplitKeepsTotalAndSourceOffset() {
        let clips = [clip(10), clip(6)]
        let s = StudioTimeline.split(clips, at: 4)
        XCTAssertEqual(s.map(\.duration), [4, 6, 6])
        XCTAssertEqual(s[1].sourceStart, 4)
        XCTAssertNotEqual(s[0].id, s[1].id)
        XCTAssertEqual(StudioTimeline.split(clips, at: 0.1), clips)   // too near the edge
        XCTAssertEqual(StudioTimeline.split(clips, at: 9.9), clips)
    }

    func testRemoveClosesTheGap() {
        let s = StudioTimeline.split([clip(10), clip(6)], at: 4)
        let r = StudioTimeline.remove(s, id: s[0].id)
        XCTAssertEqual(r.first?.sourceStart, 4)
        XCTAssertEqual(StudioTimeline.total(r), 12)
    }

    func testTrimAndMove() {
        let a = clip(10), b = clip(6)
        XCTAssertEqual(StudioTimeline.trimStart([a, b], at: 12)[1].sourceStart, 2)
        XCTAssertEqual(StudioTimeline.trimStart([a, b], at: 12)[1].duration, 4)
        XCTAssertEqual(StudioTimeline.trimEnd([a, b], at: 3)[0].duration, 3)
        XCTAssertEqual(StudioTimeline.move([a, b], id: a.id, by: 1).map(\.id), [b.id, a.id])
        XCTAssertEqual(StudioTimeline.move([a, b], id: a.id, by: -1), [a, b])
    }

    func testInsertSplitsAroundThePlayheadAndFitsTheRange() {
        let new = clip(5)
        XCTAssertEqual(StudioTimeline.insert(new, into: [clip(10), clip(6)], at: 4, limit: 18)
            .map(\.duration), [4, 5, 6, 3])
        XCTAssertEqual(StudioTimeline.insert(new, into: [], at: 0, limit: 3).map(\.duration), [3])
        XCTAssertEqual(StudioTimeline.insert(new, into: [clip(10)], at: 10, limit: 60).last?.id, new.id)
        XCTAssertEqual(StudioTimeline.fit([clip(10), clip(10)], to: 10.1).count, 1)   // sliver dropped
    }

    func testIndexAtTime() {
        let clips = [clip(10), clip(6)]
        XCTAssertEqual(StudioTimeline.index(at: 0, in: clips), 0)
        XCTAssertEqual(StudioTimeline.index(at: 10, in: clips), 1)
        XCTAssertEqual(StudioTimeline.index(at: 99, in: clips), 1)
        XCTAssertNil(StudioTimeline.index(at: 0, in: []))
    }
}
