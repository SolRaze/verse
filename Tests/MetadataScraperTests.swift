import XCTest

/// The "fetch never worked" regression: empty artist must not emit `artist:""`.
final class QueryBuilderTests: XCTestCase {
    func testEmptyArtistOmitted() {
        let q = MetadataScraper.buildQuery(title: "Song", artist: "", filename: "f")
        XCTAssertEqual(q, "recording:\"Song\"")
    }
    func testBothPresent() {
        let q = MetadataScraper.buildQuery(title: "Song", artist: "Band", filename: "f")
        XCTAssertEqual(q, "recording:\"Song\" AND artist:\"Band\"")
    }
    func testFilenameFallbackAndQuoteStripping() {
        let q = MetadataScraper.buildQuery(title: "", artist: "", filename: "a \"b\"")
        XCTAssertEqual(q, "recording:\"a  b \"")
    }
}
@testable import Verse

/// Online metadata: the pure MusicBrainz `recording` search parse — offline, no network.
final class MetadataScraperTests: XCTestCase {

    func testParsesRecordingSearch() throws {
        // Canned top-hit slice of a real recording-search response (placeholder values).
        let json = """
        {"count":1,"recordings":[{
          "id":"11111111-1111-1111-1111-111111111111",
          "title":"Placeholder Song",
          "artist-credit":[
            {"name":"First Artist","joinphrase":" & "},
            {"name":"Second Artist"}
          ],
          "releases":[
            {"id":"22222222-2222-2222-2222-222222222222","title":"Placeholder Album"}
          ]
        }]}
        """
        let parsed = try XCTUnwrap(MetadataScraper.parse(Data(json.utf8)))
        XCTAssertEqual(parsed.title, "Placeholder Song")
        XCTAssertEqual(parsed.artist, "First ArtistSecond Artist")   // artist-credit names joined
        XCTAssertEqual(parsed.album, "Placeholder Album")
        XCTAssertEqual(parsed.releaseMBID, "22222222-2222-2222-2222-222222222222")
    }

    func testNoRecordingsYieldsNil() {
        XCTAssertNil(MetadataScraper.parse(Data(#"{"count":0,"recordings":[]}"#.utf8)))
    }

    func testParsesReleaseCandidates() {
        let json = """
        {"releases":[
          {"id":"aaaa","title":"Album One","date":"2019-05-01","track-count":10,
           "artist-credit":[{"name":"Band"}]},
          {"id":"bbbb","title":"Album Two","media":[{"track-count":6},{"track-count":6}]}
        ]}
        """
        let cands = MetadataScraper.parseCandidates(Data(json.utf8))
        XCTAssertEqual(cands.count, 2)
        XCTAssertEqual(cands[0].album, "Album One")
        XCTAssertEqual(cands[0].artist, "Band")
        XCTAssertEqual(cands[0].year, "2019")
        XCTAssertEqual(cands[0].trackCount, 10)
        XCTAssertEqual(cands[1].trackCount, 12)   // summed across two discs when track-count absent
    }

    // MARK: - matchTracklist (folder files -> release tracklist)

    private func ti(_ title: String, _ track: Int, _ disc: Int = 1) -> MetadataScraper.TrackInfo {
        MetadataScraper.TrackInfo(title: title, track: track, disc: disc)
    }

    func testMatchByTitleThenPositional() {
        let tracks = [ti("Intro", 1), ti("Verse", 2), ti("Outro", 3)]
        // Exact/substring titles resolve; the odd one out falls to the remaining slot.
        let m = MetadataScraper.matchTracklist(fileTitles: ["outro", "Intro (Live)", "mystery"],
                                               tracks: tracks)
        XCTAssertEqual(m[0]?.track, 3)   // "outro" == "Outro"
        XCTAssertEqual(m[1]?.track, 1)   // "Intro (Live)" contains "Intro"
        XCTAssertEqual(m[2]?.track, 2)   // positional fill: only "Verse" left, counts match
    }

    func testDuplicateTitlesDoNotCollide() {
        // Two files literally named the same must not both take track 1.
        let tracks = [ti("Skit", 1), ti("Skit", 2)]
        let m = MetadataScraper.matchTracklist(fileTitles: ["Skit", "Skit"], tracks: tracks)
        XCTAssertEqual(Set(m.compactMap { $0?.track }), [1, 2])
    }

    func testNoPositionalFillWhenCountsDiffer() {
        // 3 files, 2 tracks: unmatched files stay nil rather than grabbing a wrong track.
        let tracks = [ti("A", 1), ti("B", 2)]
        let m = MetadataScraper.matchTracklist(fileTitles: ["A", "X", "Y"], tracks: tracks)
        XCTAssertEqual(m[0]?.track, 1)
        XCTAssertNil(m[1])
        XCTAssertNil(m[2])
    }

    func testParsesDiscAwareTracklist() {
        let json = """
        {"media":[
          {"position":1,"tracks":[
            {"position":1,"title":"One"},{"position":2,"title":"Two"}]},
          {"position":2,"tracks":[
            {"position":1,"title":"Three"}]}
        ]}
        """
        let tracks = MetadataScraper.parseTracklist(Data(json.utf8))
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[2].disc, 2)
        XCTAssertEqual(tracks[2].track, 1)
        XCTAssertEqual(tracks[0].title, "One")
    }
}
