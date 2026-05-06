import Testing
import Foundation
@testable import HoehnPhotosOrganizer

struct CustomPaletteTests {

    // MARK: - PaintColor.paintMedium

    @Test func testPaintColorPaintMediumParsesKnownRawValue() {
        let color = PaintColor(
            paletteId: "p1", name: "Ultramarine Blue",
            red: 0.1, green: 0.1, blue: 0.6,
            medium: .oil, transparency: .transparent
        )
        #expect(color.paintMedium == .oil,
                "paintMedium must decode the stored raw value back to the enum case")
    }

    @Test func testPaintColorPaintMediumReturnsNilForUnknownRawValue() {
        var color = PaintColor(
            paletteId: "p1", name: "Mystery Paint",
            red: 0.5, green: 0.5, blue: 0.5,
            medium: .acrylic, transparency: .opaque
        )
        color.medium = "encaustic"
        #expect(color.paintMedium == nil,
                "paintMedium must return nil when the stored string has no matching enum case")
    }

    // MARK: - PaintColor.paintTransparency

    @Test func testPaintColorPaintTransparencyParsesKnownRawValue() {
        let color = PaintColor(
            paletteId: "p1", name: "Cadmium Yellow",
            red: 1.0, green: 0.9, blue: 0.0,
            medium: .watercolor, transparency: .semiOpaque
        )
        #expect(color.paintTransparency == .semiOpaque,
                "paintTransparency must decode the stored raw value back to the enum case")
    }

    // MARK: - CustomPalette.touchingModified

    @Test func testTouchingModifiedUpdatesModifiedAtToNow() throws {
        let past = Date(timeIntervalSince1970: 0)
        let palette = CustomPalette(name: "Earthy Tones", createdAt: past, modifiedAt: past)

        let touched = palette.touchingModified()

        let touchedDate = try #require(touched.modifiedDate,
                                       "touchingModified() must produce a parseable modifiedAt date")
        #expect(touchedDate > past,
                "touchingModified() must set modifiedAt to a date later than the original")
    }

    // MARK: - CustomPalette.createdDate

    @Test func testCreatedDateRoundTripsThroughISO8601() {
        let now = Date()
        let palette = CustomPalette(name: "Test Palette", createdAt: now)
        let roundTripped = palette.createdDate

        // Allow 1-second tolerance because ISO8601 has 1-second resolution.
        #expect(abs((roundTripped?.timeIntervalSince(now) ?? .infinity)) < 1.0,
                "createdDate must round-trip through ISO8601DateFormatter within 1-second accuracy")
    }
}
