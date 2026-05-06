import Testing
@testable import HoehnPhotosOrganizer

struct AdjustmentClipboardTests {

    private func makeAdjustment(exposure: Double = 1.0) -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.exposure = exposure
        return a
    }

    @Test
    func testClipboardIsNilInitially() {
        let clipboard = AdjustmentClipboard()
        #expect(clipboard.copiedAdjustment == nil)
        #expect(clipboard.sourcePhotoId == nil)
        #expect(clipboard.hasContent == false)
    }

    @Test
    func testCopyAdjustmentStoresInClipboard() {
        let clipboard = AdjustmentClipboard()
        let adj = makeAdjustment(exposure: 0.5)
        clipboard.copy(adjustment: adj, fromPhoto: "IMG_001.CR3")

        #expect(clipboard.hasContent == true)
        #expect(clipboard.sourcePhotoId == "IMG_001.CR3")
        #expect(clipboard.copiedAdjustment?.exposure == 0.5)
    }

    @Test
    func testCopyOverwritesPrevious() {
        let clipboard = AdjustmentClipboard()
        clipboard.copy(adjustment: makeAdjustment(exposure: 1.0), fromPhoto: "first.CR3")
        clipboard.copy(adjustment: makeAdjustment(exposure: 2.5), fromPhoto: "second.CR3")

        #expect(clipboard.sourcePhotoId == "second.CR3")
        #expect(clipboard.copiedAdjustment?.exposure == 2.5)
    }

    // MARK: - clear

    @Test
    func testClearEmptiesClipboard() {
        let clipboard = AdjustmentClipboard()
        clipboard.copy(adjustment: makeAdjustment(), fromPhoto: "photo.CR3")
        clipboard.clear()

        #expect(clipboard.hasContent == false)
        #expect(clipboard.copiedAdjustment == nil)
        #expect(clipboard.sourcePhotoId == nil)
    }

    // MARK: - buildAdjustment

    @Test
    func testBuildAdjustmentReturnsNilWhenClipboardIsEmpty() {
        let clipboard = AdjustmentClipboard()
        let result = clipboard.buildAdjustment(for: PhotoAdjustments(), options: .all)
        #expect(result == nil, "buildAdjustment must return nil when no adjustment has been copied")
    }

    @Test
    func testBuildAdjustmentWithToneOnlyUpdatesOnlyToneFields() {
        let clipboard = AdjustmentClipboard()
        var source = PhotoAdjustments()
        source.exposure = 1.5
        source.saturation = 80   // color field — must NOT transfer with toneOnly
        clipboard.copy(adjustment: source, fromPhoto: "src.CR3")

        var target = PhotoAdjustments()
        target.saturation = 20
        let result = clipboard.buildAdjustment(for: target, options: .toneOnly)

        #expect(result?.exposure == 1.5,  "toneOnly paste must transfer exposure from source")
        #expect(result?.saturation == 20, "toneOnly paste must NOT overwrite target saturation")
    }

    @Test
    func testBuildAdjustmentWithGradeOnlyDoesNotUpdateToneFields() {
        let clipboard = AdjustmentClipboard()
        var source = PhotoAdjustments()
        source.exposure = 2.0   // tone field — must NOT transfer with gradeOnly
        clipboard.copy(adjustment: source, fromPhoto: "src.CR3")

        var target = PhotoAdjustments()
        target.exposure = 0.5
        let result = clipboard.buildAdjustment(for: target, options: .gradeOnly)

        #expect(result?.exposure == 0.5, "gradeOnly paste must NOT transfer exposure from source")
    }

    // MARK: - PasteOptions.anySelected

    @Test
    func testPasteOptionsAnySelectedReturnsFalseWhenAllFalse() {
        let none = PasteOptions(tone: false, color: false, curves: false,
                                hsl: false, colorGrading: false, colorBalance: false, calibration: false)
        #expect(none.anySelected == false, "anySelected must be false when every option is disabled")
        #expect(PasteOptions.all.anySelected == true, "PasteOptions.all must report anySelected == true")
    }
}
