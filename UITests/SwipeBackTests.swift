import XCTest

/// Issue #5: folder screens needed two swipes to pop. Nothing below can be checked without a
/// real touch — the interactive pop lives in UIKit's gesture recognizers, so a unit test can't
/// see it. One swipe, one assertion: are we back at the root.
final class SwipeBackTests: XCTestCase {

    private let folder = "ZZSwipeBackProbe"

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFolderPopsOnASingleSwipe() {
        let app = XCUIApplication()
        app.launch()

        // The app boots on the Home tab; folders live in Library.
        app.tabBars.buttons["Library"].tap()

        makeFolder(app)
        defer { deleteFolder(app) }

        app.staticTexts[folder].tap()
        XCTAssertTrue(app.navigationBars[folder].waitForExistence(timeout: 3),
                      "never landed on the folder screen — the row didn't push")

        edgeSwipe(app)

        // The bug: the first swipe is eaten by a competing pan recognizer, so this bar is still
        // here and only a second swipe pops it.
        XCTAssertTrue(waitForDisappearance(app.navigationBars[folder], timeout: 3),
                      "still on \(folder) after one swipe — first swipe was eaten (issue #5)")
    }

    // MARK: helpers

    private func edgeSwipe(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .default,
                    thenHoldForDuration: 0.1)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func makeFolder(_ app: XCUIApplication) {
        app.buttons["libraryMenu"].tap()
        app.buttons["New Folder"].tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "New Folder alert never appeared")
        field.typeText(folder)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[folder].waitForExistence(timeout: 3), "folder wasn't created")
    }

    private func deleteFolder(_ app: XCUIApplication) {
        let row = app.staticTexts[folder]
        guard row.exists else { return }
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 2) { delete.tap() }
    }
}
