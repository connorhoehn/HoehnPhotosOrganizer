import Testing
@testable import HoehnPhotosOrganizer

struct PhotoAdjustmentsTests {

    // MARK: - isIdentity

    @Test func testIsIdentityTrueForDefaultValues() {
        let adj = PhotoAdjustments()
        #expect(adj.isIdentity, "Default PhotoAdjustments must report isIdentity == true")
    }

    @Test func testIsIdentityFalseWhenExposureNonZero() {
        var adj = PhotoAdjustments()
        adj.exposure = 0.5
        #expect(!adj.isIdentity, "Non-zero exposure must break identity")
    }

    @Test func testIsIdentityFalseWhenUseToneCurveEnabled() {
        var adj = PhotoAdjustments()
        adj.useToneCurve = true
        #expect(!adj.isIdentity, "useToneCurve = true must break identity")
    }

    @Test func testIsIdentityFalseWhenHSLModified() {
        var adj = PhotoAdjustments()
        adj.hsl.red.saturation = 20
        #expect(!adj.isIdentity, "Modified HSL channel must break identity")
    }

    // MARK: - encodeToJSON / decode(from:)

    @Test func testEncodeDecodeRoundTrip() throws {
        var adj = PhotoAdjustments()
        adj.exposure = 1.2
        adj.contrast = -15
        adj.saturation = 30
        adj.colorGrading.midtones.hue = 45

        let json = try #require(adj.encodeToJSON(), "encodeToJSON must return non-nil for valid struct")
        let decoded = try #require(PhotoAdjustments.decode(from: json), "decode(from:) must succeed on its own encoded output")

        #expect(abs(decoded.exposure - 1.2) < 1e-9)
        #expect(decoded.contrast == -15)
        #expect(decoded.saturation == 30)
        #expect(decoded.colorGrading.midtones.hue == 45)
    }

    @Test func testDecodeFromInvalidJSONStringReturnsNil() {
        #expect(PhotoAdjustments.decode(from: "not json at all") == nil)
        #expect(PhotoAdjustments.decode(from: "[1, 2, 3]") == nil,
                "A JSON array is not a valid PhotoAdjustments object")
    }
}
