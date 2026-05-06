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

    // MARK: - toPhotoAdjustments

    func testToPhotoAdjustmentsTransfersNonNilFields() throws {
        let suggested = SuggestedAdjustments(
            exposure: 1.2, contrast: 20, highlights: -30, shadows: 15,
            whites: nil, blacks: nil, saturation: 10, vibrance: nil, rationale: nil
        )
        let regional = RegionalAdjustment(
            regionLabel: "sky",
            regionDescription: "Upper sky region",
            adjustments: suggested,
            geometryHint: nil
        )
        let pa = regional.toPhotoAdjustments()

        XCTAssertEqual(pa.exposure,    1.2,  accuracy: 1e-9)
        XCTAssertEqual(pa.contrast,    20)
        XCTAssertEqual(pa.highlights,  -30)
        XCTAssertEqual(pa.shadows,     15)
        XCTAssertEqual(pa.saturation,  10)
    }

    func testToPhotoAdjustmentsKeepsDefaultsForNilFields() throws {
        // Nil fields in SuggestedAdjustments must not alter the PhotoAdjustments defaults.
        let suggested = SuggestedAdjustments(
            exposure: nil, contrast: nil, highlights: nil, shadows: nil,
            whites: nil, blacks: nil, saturation: nil, vibrance: nil, rationale: nil
        )
        let regional = RegionalAdjustment(
            regionLabel: "foreground",
            regionDescription: "Ground region",
            adjustments: suggested,
            geometryHint: nil
        )
        let pa = regional.toPhotoAdjustments()
        let defaults = PhotoAdjustments()

        XCTAssertEqual(pa.exposure,   defaults.exposure,   accuracy: 1e-9)
        XCTAssertEqual(pa.saturation, defaults.saturation)
        XCTAssertEqual(pa.contrast,   defaults.contrast)
    }

    func testToPhotoAdjustmentsAllFieldsRoundTrip() throws {
        let suggested = SuggestedAdjustments(
            exposure: -0.5, contrast: -10, highlights: 25, shadows: -20,
            whites: 5, blacks: -5, saturation: -30, vibrance: 15, rationale: "Test"
        )
        let regional = RegionalAdjustment(
            regionLabel: "midground",
            regionDescription: "Middle region",
            adjustments: suggested,
            geometryHint: "center"
        )
        let pa = regional.toPhotoAdjustments()

        XCTAssertEqual(pa.exposure,    -0.5, accuracy: 1e-9)
        XCTAssertEqual(pa.highlights,  25)
        XCTAssertEqual(pa.shadows,     -20)
        XCTAssertEqual(pa.whites,      5)
        XCTAssertEqual(pa.blacks,      -5)
        XCTAssertEqual(pa.vibrance,    15)
    }
}
