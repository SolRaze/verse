import XCTest
@testable import Verse

/// The cheap cache predicates that replaced decode-and-read probes. They are only correct if they
/// agree with the expensive calls they stand in for — in particular on the zero-byte negative
/// marker, which is why `Artwork.exists(for:)` could not be used for this.
final class CachePredicateTests: XCTestCase {
    private var keys: [String] = []

    override func tearDown() {
        keys.forEach { Artwork.invalidate(key: $0) }
        keys = []
        super.tearDown()
    }

    private func newKey() -> String {
        let k = UUID().uuidString
        keys.append(k)
        return k
    }

    func testHasArtIsFalseForAMissingKey() {
        XCTAssertFalse(Artwork.hasArt(for: newKey()))
    }

    func testHasArtIsFalseForTheNegativeMarkerThatExistsReportsTrue() async {
        let key = newKey()
        // A file with no embedded artwork makes store(from:) write the empty negative marker.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(key + ".mp3")
        try? Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        await Artwork.store(from: empty, key: key)

        XCTAssertTrue(Artwork.exists(for: key), "the marker is on disk")
        XCTAssertFalse(Artwork.hasArt(for: key), "but it is not artwork")
        XCTAssertNil(Artwork.image(for: key), "hasArt must agree with image(for:)")
    }

    func testHasArtIsTrueForRealArtwork() {
        let key = newKey()
        let img = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        Artwork.store(image: img, key: key)
        XCTAssertTrue(Artwork.hasArt(for: key))
        XCTAssertNotNil(Artwork.image(for: key), "hasArt must agree with image(for:)")
    }

    func testHasLyricsMatchesCachedRawIncludingTheNegativeCache() {
        let found = UUID().uuidString, miss = UUID().uuidString, absent = UUID().uuidString
        LyricsResolver.attach(lrcText: "[00:01.00]line", cacheKey: found)
        LyricsResolver.attach(lrcText: "", cacheKey: miss)   // the resolver's negative cache
        // ponytail: the negative marker is removable through the real API; the found entry is a
        // UUID-keyed file in the purgeable Caches dir, and adding a production purge just to
        // tidy a test is the wrong trade.
        defer { LyricsResolver.invalidateNegative(cacheKey: miss) }

        for key in [found, miss, absent] {
            let expensive = !(LyricsResolver.cachedRaw(for: key) ?? "").isEmpty
            XCTAssertEqual(LyricsResolver.hasLyrics(for: key), expensive,
                           "hasLyrics disagreed with cachedRaw for \(key)")
        }
        XCTAssertTrue(LyricsResolver.hasLyrics(for: found))
        XCTAssertFalse(LyricsResolver.hasLyrics(for: miss))
        XCTAssertFalse(LyricsResolver.hasLyrics(for: absent))
    }
}
