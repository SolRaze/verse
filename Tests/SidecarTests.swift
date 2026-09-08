import XCTest
import UIKit
@testable import Verse

/// "Colour From Cover": a solid-red cover must yield a red-ish accent, not grey.
final class DominantColorTests: XCTestCase {
    func testRedImageGivesRedAccent() throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let c = try XCTUnwrap(Artwork.dominantColor(img))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(r, g + 0.3)   // clearly red-dominant
        XCTAssertGreaterThan(r, b + 0.3)
    }
}

/// In-place metadata: sidecar tags win over filename parsing, and a re-import keeps
/// item identity so play counts / likes / id-keyed caches survive.
@MainActor
final class SidecarTests: XCTestCase {

    func testSidecarReadAndReimportKeepsIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("SidecarTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("not really audio".utf8).write(to: root.appendingPathComponent("Nobody - Placeholder.mp3"))
        try Data(#"{"title":"Real Title","artist":"Real Artist","liked":true,"album":"Real Album","playCount":5}"#.utf8)
            .write(to: root.appendingPathComponent("Nobody - Placeholder.verse.json"))

        let store = LibraryStore()
        let rootName = root.lastPathComponent
        defer { store.removeFolder([rootName]); store.flush() }   // keep the test-host library clean

        store.add(pickedURLs: [root])
        let first = try XCTUnwrap(store.items.first { $0.folders == [rootName] })
        XCTAssertEqual(first.title, "Real Title")     // sidecar beat the filename parse
        XCTAssertEqual(first.artist, "Real Artist")
        XCTAssertTrue(first.liked)
        XCTAssertEqual(first.album, "Real Album")     // album rides the sidecar
        XCTAssertEqual(first.playCount, 5)            // play history restored (rebuild path)

        store.recordPlay(first)
        store.add(pickedURLs: [root])                 // re-import the same tree
        let again = try XCTUnwrap(store.items.first { $0.folders == [rootName] })
        XCTAssertEqual(again.id, first.id)            // identity survived
        XCTAssertEqual(again.playCount, 6)            // in-app history beats the sidecar's
    }

    /// #6c: a hand-edited field is frozen against auto-fetch, and the freeze rides the sidecar —
    /// if it didn't, a re-import would forget it and the next online pass would undo the edit.
    func testFrozenFieldsSurviveTheSidecar() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FreezeTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("not really audio".utf8).write(to: root.appendingPathComponent("Nobody - Frozen.mp3"))
        try Data(#"{"title":"Kept Title","artist":"Kept Artist","album":"Kept Album","frozenFields":["title","album"]}"#.utf8)
            .write(to: root.appendingPathComponent("Nobody - Frozen.verse.json"))

        let store = LibraryStore()
        let rootName = root.lastPathComponent
        defer { store.removeFolder([rootName]); store.flush() }

        store.add(pickedURLs: [root])
        let item = try XCTUnwrap(store.items.first { $0.folders == [rootName] })
        XCTAssertTrue(item.isFrozen(.title))
        XCTAssertTrue(item.isFrozen(.album))
        XCTAssertFalse(item.isFrozen(.artist))    // untouched fields still take online metadata
        XCTAssertFalse(item.isFrozen(.artwork))
    }

    /// An old sidecar has no `frozenFields` key at all; it must still decode, with nothing frozen.
    func testSidecarWithoutFrozenFieldsDecodes() throws {
        let json = #"{"title":"T","artist":"A"}"#
        let tags = try JSONDecoder().decode(SidecarTags.self, from: Data(json.utf8))
        XCTAssertNil(tags.frozenFields)
    }
}
