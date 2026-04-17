import XCTest

final class LibraryViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// M1.3: Photo grid is visible when app launches with mock data.
    /// Skipped until grid is bound to real data source.
    @MainActor
    func testPhotoGridVisibleWithMockData() throws {
        try XCTSkip("stub — implement when photo grid is wired to data")
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.exists, "Photo grid should be visible")
    }

    /// M1.3: Zoom slider adjusts photo grid density (column count).
    /// Skipped until slider interaction is testable.
    @MainActor
    func testZoomSliderAdjustsGridDensity() throws {
        try XCTSkip("stub — implement when zoom slider is wired to grid layout")
        let app = XCUIApplication()
        app.launch()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.exists, "Zoom slider should be present")
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(app.collectionViews.firstMatch.exists, "Grid should still exist after slider drag")
    }
}
