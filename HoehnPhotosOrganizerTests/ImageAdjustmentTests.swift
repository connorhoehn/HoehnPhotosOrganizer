import Testing
@testable import HoehnPhotosOrganizer

struct ImageAdjustmentTests {

    // MARK: - ToneCurvePreset endpoints

    @Test
    func testLinearPresetHasIdentityEndpoints() {
        let pts = ImageAdjustment.ToneCurvePreset.linear.points
        #expect(pts.count == 2)
        #expect(pts.first == CurvePoint(input: 0, output: 0),   "Linear start must be (0, 0)")
        #expect(pts.last  == CurvePoint(input: 255, output: 255), "Linear end must be (255, 255)")
    }

    @Test
    func testContrastPresetsPreserveBlackAndWhiteEndpoints() {
        // Both contrast presets must anchor at (0,0) and (255,255) to avoid clipping.
        for preset in [ImageAdjustment.ToneCurvePreset.mediumContrast,
                       ImageAdjustment.ToneCurvePreset.strongContrast] {
            let pts = preset.points
            #expect(pts.first == CurvePoint(input: 0, output: 0),
                    "\(preset.rawValue): first control point must be (0, 0)")
            #expect(pts.last == CurvePoint(input: 255, output: 255),
                    "\(preset.rawValue): last control point must be (255, 255)")
        }
    }

    // MARK: - displaySummary

    @Test
    func testDisplaySummaryForToneCurveIncludesPointCount() {
        let adj = ImageAdjustment.toneCurve([CurvePoint(input: 0, output: 0),
                                             CurvePoint(input: 128, output: 140),
                                             CurvePoint(input: 255, output: 255)])
        #expect(adj.displaySummary.contains("3"), "Tone curve summary must state the number of control points")
        #expect(adj.displaySummary.lowercased().contains("curve"))
    }

    @Test
    func testDisplaySummaryForLevelsIncludesExposureValue() {
        let adj = ImageAdjustment.levels(blacks: -10, whites: 5, shadows: 20, highlights: -30, exposure: 1.5)
        let summary = adj.displaySummary
        #expect(summary.contains("1.50") || summary.contains("exp:1.50"),
                "Levels summary must include the formatted exposure value")
    }

    // MARK: - JSON round-trip with associated values

    @Test
    func testImageAdjustmentEncodesAndDecodesWithAssociatedValues() throws {
        let original = ImageAdjustment.basic(contrast: 20, saturation: -10, vibrance: 15)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageAdjustment.self, from: data)

        guard case let .basic(c, s, v) = decoded.type else {
            Issue.record("Decoded type must be .basic")
            return
        }
        #expect(c == 20,  "contrast must survive JSON round-trip")
        #expect(s == -10, "saturation must survive JSON round-trip")
        #expect(v == 15,  "vibrance must survive JSON round-trip")
    }
}
