import XCTest
@testable import HoehnPhotosOrganizer

final class EditorialFeedbackTests: XCTestCase {

    func testRegionalAdjustmentDecode() throws {
        let json = """
        {
            "composition_score": 8,
            "print_readiness": "ready",
            "analysis": "Strong image.",
            "adjustments": null,
            "crop_suggestions": [],
            "masking_hints": [],
            "strengths": ["Good light"],
            "areas_for_improvement": [],
            "suggested_edit_directions": [],
            "metadata_enrichment": null,
            "geometry_correction": null,
            "regional_adjustments": [
                {
                    "region_label": "sky",
                    "region_description": "Upper portion of image containing sky",
                    "geometry_hint": "upper third",
                    "adjustments": {
                        "exposure": 0.5,
                        "highlights": -20
                    }
                }
            ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let feedback = try JSONDecoder().decode(EditorialFeedback.self, from: data)

        XCTAssertNotNil(feedback.regionalAdjustments, "Expected regionalAdjustments to be non-nil")
        XCTAssertEqual(feedback.regionalAdjustments?.count, 1)

        let region = try XCTUnwrap(feedback.regionalAdjustments?.first)
        XCTAssertEqual(region.regionLabel, "sky")
        XCTAssertEqual(region.geometryHint, "upper third")
        XCTAssertEqual(region.adjustments.exposure, 0.5)
    }

    func testEditorialFeedbackBackwardCompat() throws {
        // Old JSON without regional_adjustments should decode cleanly
        let json = """
        {
            "composition_score": 7,
            "print_readiness": "needs work",
            "analysis": "Decent shot.",
            "adjustments": null,
            "crop_suggestions": [],
            "masking_hints": ["Sky area is overexposed"],
            "strengths": ["Interesting subject"],
            "areas_for_improvement": ["Improve highlights"],
            "suggested_edit_directions": [],
            "metadata_enrichment": null,
            "geometry_correction": null
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let feedback = try JSONDecoder().decode(EditorialFeedback.self, from: data)

        XCTAssertNil(feedback.regionalAdjustments, "Expected regionalAdjustments to be nil for old JSON")
        XCTAssertEqual(feedback.maskingHints, ["Sky area is overexposed"])
        XCTAssertEqual(feedback.compositionScore, 7)
    }
}
