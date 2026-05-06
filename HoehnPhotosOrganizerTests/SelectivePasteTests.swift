import Testing
@testable import HoehnPhotosOrganizer

@Suite struct SelectivePasteTests {

    // MARK: - Helpers

    private func makeSource() -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.exposure = 2.0
        a.contrast = 30
        a.saturation = 50
        a.vibrance = 40
        a.useToneCurve = true
        a.toneCurvePreset = "S-Curve"
        a.hsl = PhotoAdjustments.HSLAdjustments()
        return a
    }

    private func makeTarget() -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.exposure = 0.0
        a.contrast = 0
        a.saturation = 0
        a.vibrance = 0
        a.useToneCurve = false
        a.toneCurvePreset = nil
        return a
    }

    // MARK: - Tests

    @Test func testSelectivePasteToneOnlySkipsCurves() {
        let clipboard = AdjustmentClipboard()
        clipboard.copy(adjustment: makeSource(), fromPhoto: "src")

        let result = clipboard.buildAdjustment(for: makeTarget(), options: .toneOnly)

        #expect(result != nil)
        // Tone fields copied from source
        #expect(result?.exposure == 2.0)
        #expect(result?.contrast == 30)
        // Curves NOT copied — target had useToneCurve=false, toneCurvePreset=nil
        #expect(result?.useToneCurve == false)
        #expect(result?.toneCurvePreset == nil)
        // Color NOT copied — target had saturation=0
        #expect(result?.saturation == 0)
        #expect(result?.vibrance == 0)
    }

    @Test func testSelectivePasteAllCopiesEverything() {
        let clipboard = AdjustmentClipboard()
        let source = makeSource()
        clipboard.copy(adjustment: source, fromPhoto: "src")

        let result = clipboard.buildAdjustment(for: makeTarget(), options: .all)

        #expect(result != nil)
        #expect(result?.exposure == source.exposure)
        #expect(result?.contrast == source.contrast)
        #expect(result?.saturation == source.saturation)
        #expect(result?.vibrance == source.vibrance)
        #expect(result?.useToneCurve == source.useToneCurve)
        #expect(result?.toneCurvePreset == source.toneCurvePreset)
    }

    @Test func testSelectivePasteCustomGroupsApplied() {
        let clipboard = AdjustmentClipboard()
        clipboard.copy(adjustment: makeSource(), fromPhoto: "src")

        // Color-only paste: only saturation/vibrance should transfer
        let colorOnly = PasteOptions(
            tone: false, color: true, curves: false,
            hsl: false, colorGrading: false, colorBalance: false, calibration: false
        )
        let result = clipboard.buildAdjustment(for: makeTarget(), options: colorOnly)

        #expect(result != nil)
        // Color fields copied from source
        #expect(result?.saturation == 50)
        #expect(result?.vibrance == 40)
        // Tone NOT copied — target had exposure=0
        #expect(result?.exposure == 0.0)
        #expect(result?.contrast == 0)
        // Curves NOT copied — target had useToneCurve=false
        #expect(result?.useToneCurve == false)
        #expect(result?.toneCurvePreset == nil)
    }
}
