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
}
