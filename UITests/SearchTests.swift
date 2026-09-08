import XCTest

/// Follow-up: the dock's search field "breaks" after tapping the clear (x) button.
/// Drives the real field: open search, type, clear, type again — the field must keep working
/// and keep showing what was typed.
final class SearchTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testSearchFieldSurvivesClear() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Search"].firstMatch.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no search field after tapping the pill")
        field.tap()
        field.typeText("abc")
        XCTAssertEqual(field.value as? String, "abc", "typed input isn't shown")

        let clear = field.buttons["Clear text"]
        XCTAssertTrue(clear.waitForExistence(timeout: 2), "no clear button while text present")
        clear.tap()

        // The reported break: after x, the field stops reflecting input.
        field.typeText("xyz")
        XCTAssertEqual(field.value as? String, "xyz", "field broke after clear")
    }
}
