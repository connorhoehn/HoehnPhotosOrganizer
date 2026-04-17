import XCTest

final class ImportWizardTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// M1.4: Tapping the Import button opens the Import Wizard sheet.
    /// Skipped until Import button accessibility label is confirmed.
    @MainActor
    func testImportWizardOpensFromImportButton() throws {
        try XCTSkip("stub — implement when Import button has accessibility identifier")
        let app = XCUIApplication()
        app.launch()
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.exists, "Import button should be visible in sidebar")
        importButton.tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 2), "Import Wizard sheet should appear")
    }

    /// M1.4: Import Wizard displays all five ImportStage steps.
    /// Skipped until wizard stage titles are set as accessibility labels.
    @MainActor
    func testImportWizardShowsAllStages() throws {
        try XCTSkip("stub — implement when wizard stage labels are finalized")
        let app = XCUIApplication()
        app.launch()
        app.buttons["Import"].tap()
        let stageNames = ["Connect Drive", "Extract Preview", "Generate Proxy", "Extract Metadata", "Done"]
        for name in stageNames {
            XCTAssertTrue(
                app.staticTexts[name].waitForExistence(timeout: 2),
                "Import stage '\(name)' should be visible in wizard"
            )
        }
    }
}
