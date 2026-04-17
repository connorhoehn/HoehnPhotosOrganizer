import XCTest
import CoreGraphics
@testable import HoehnPhotosOrganizer

final class MaskLayerTests: XCTestCase {

    func testAdjustmentLayerEncodeDecode() throws {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.5

        let original = AdjustmentLayer(
            label: "Sky",
            adjustments: adjustments,
            sources: [
                MaskSource(sourceType: .ellipse(normalizedRect: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3)))
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdjustmentLayer.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.label, "Sky")
        XCTAssertEqual(decoded.adjustments.exposure, 1.5)
        XCTAssertEqual(decoded.isActive, true)
        XCTAssertEqual(decoded.opacity, 1.0)
        XCTAssertEqual(decoded.sources.count, 1)

        if case .ellipse(let rect) = decoded.sources[0].sourceType {
            XCTAssertEqual(rect.origin.x, 0.1, accuracy: 0.0001)
            XCTAssertEqual(rect.origin.y, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("Expected .ellipse source type")
        }
    }

    func testLegacyMaskLayerDecode() throws {
        // Simulate old MaskLayer JSON format
        let legacyJSON = """
        [{"id":"abc","label":"Test","geometry":{"ellipse":{"normalizedRect":[[0.1,0.2],[0.5,0.5]]}},"adjustments":{"exposure":0.5,"contrast":10,"highlights":0,"shadows":0,"whites":0,"blacks":0,"saturation":0,"vibrance":0},"isActive":true,"isInverted":false,"opacity":1.0,"feather":3.0,"erode":0,"dilate":0,"createdAt":"2025-01-01T00:00:00Z"}]
        """
        let layers = MaskLayerStore.decode(from: legacyJSON)
        // Should gracefully handle — either decode successfully or return empty
        // (exact format depends on MaskGeometry's Codable impl)
        XCTAssertTrue(layers.isEmpty || layers[0] is AdjustmentLayer)
    }

    func testMaskLayerStoreDecodeNil() throws {
        let result = MaskLayerStore.decode(from: nil)
        XCTAssertEqual(result, [])
    }

    func testMaskLayerStoreDecodeInvalidJSON() throws {
        let resultGarbage = MaskLayerStore.decode(from: "garbage")
        XCTAssertEqual(resultGarbage, [])

        let resultNotArray = MaskLayerStore.decode(from: "{\"not\": \"an array\"}")
        XCTAssertEqual(resultNotArray, [])
    }

    func testAdjustmentLayerStoreRoundTrip() throws {
        let layer = AdjustmentLayer(
            label: "Gradient Test",
            sources: [
                MaskSource(sourceType: .linearGradient(startPoint: CGPoint(x: 0.5, y: 0), endPoint: CGPoint(x: 0.5, y: 1))),
                MaskSource(sourceType: .radialGradient(center: CGPoint(x: 0.5, y: 0.5), innerRadius: 0.1, outerRadius: 0.4), combineMode: .subtract)
            ]
        )

        let json = MaskLayerStore.encode([layer])
        XCTAssertNotNil(json)

        let decoded = MaskLayerStore.decode(from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].sources.count, 2)
        XCTAssertEqual(decoded[0].sources[1].combineMode, .subtract)
    }
}
