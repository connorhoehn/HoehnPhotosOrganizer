import XCTest

final class AppShellTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// M1.1: Three-panel app shell renders without crash.
    /// Skipped until real DB is wired in plan 01-02.
    @MainActor
    func testAppShellRendersWithoutCrash() throws {
        try XCTSkip("stub — implement when real DB is wired")
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.exists, "App should launch and exist")
    }
}
