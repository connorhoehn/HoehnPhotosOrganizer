import XCTest
import CoreImage
import CoreGraphics
@testable import HoehnPhotosOrganizer

final class MaskRenderingTests: XCTestCase {

    // MARK: - testBuildRectMaskExtent

    func testBuildRectMaskExtent() throws {
        let imageExtent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rect = CGRect(x: 50, y: 50, width: 100, height: 100)
        let mask = MaskRenderingService.buildRectMask(rect: rect, imageExtent: imageExtent)
        XCTAssertEqual(mask.extent, imageExtent, "buildRectMask extent must match imageExtent")
    }

    // MARK: - testBuildEllipseMaskExtent

    func testBuildEllipseMaskExtent() throws {
        let imageExtent = CGRect(x: 0, y: 0, width: 400, height: 300)
        let mask = MaskRenderingService.buildEllipseMask(
            center: CGPoint(x: 200, y: 150),
            radiusX: 80,
            radiusY: 60,
            imageExtent: imageExtent
        )
        XCTAssertEqual(mask.extent, imageExtent, "buildEllipseMask extent must match imageExtent")
    }

    // MARK: - testBlendWithMaskNotNil

    func testBlendWithMaskNotNil() throws {
        let width = 100, height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            XCTFail("Could not create CGContext")
            return
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            XCTFail("Could not make CGImage")
            return
        }

        let base = CIImage(cgImage: cgImage)
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        let layer = AdjustmentLayer(
            label: "Test",
            adjustments: PhotoAdjustments(),
            sources: [MaskSource(sourceType: .rectangle(normalizedRect: fullRect))]
        )

        let result = MaskRenderingService.applyAdjustmentLayers(
            [layer],
            base: base,
            sourceCG: cgImage
        )

        XCTAssertFalse(result.extent.isEmpty, "applyAdjustmentLayers must return a non-empty CIImage")
    }
}
