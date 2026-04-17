import XCTest
@testable import HoehnPhotosOrganizer
import simd

final class PBNFacetBuilderTests: XCTestCase {

    let builder = FacetBuilder()

    // MARK: - buildFacets

    func testSolidImageProducesOneFacet() {
        // 10x10 image, all pixels label 0
        let labels = [Int32](repeating: 0, count: 100)
        let (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }
        let active = facets.filter { !$0.isDeleted }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].pixelCount, 100)
        XCTAssertTrue(facetMap.allSatisfy { $0 == 0 })
    }

    func testTwoColorImageProducesTwoFacets() {
        // 10x10: top 5 rows = label 0, bottom 5 rows = label 1
        var labels = [Int32](repeating: 0, count: 100)
        for y in 5..<10 {
            for x in 0..<10 {
                labels[y * 10 + x] = 1
            }
        }
        let (_, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }
        let active = facets.filter { !$0.isDeleted }
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active[0].pixelCount, 50)
        XCTAssertEqual(active[1].pixelCount, 50)
    }

    func testDisconnectedRegionsCreateSeparateFacets() {
        // 10x10: two 3x3 blocks of label 1 in corners, rest label 0
        var labels = [Int32](repeating: 0, count: 100)
        for y in 0..<3 { for x in 0..<3 { labels[y * 10 + x] = 1 } }
        for y in 7..<10 { for x in 7..<10 { labels[y * 10 + x] = 1 } }

        let (_, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }
        let active = facets.filter { !$0.isDeleted }
        // Should be 3 facets: the background (label 0) + two disconnected label 1 regions
        XCTAssertEqual(active.count, 3)
    }

    func testNeighborDetection() {
        // Left half = 0, right half = 1
        var labels = [Int32](repeating: 0, count: 100)
        for y in 0..<10 { for x in 5..<10 { labels[y * 10 + x] = 1 } }

        let (_, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }
        let active = facets.filter { !$0.isDeleted }
        XCTAssertEqual(active.count, 2)
        // Each should be a neighbor of the other
        XCTAssertTrue(active[0].neighborIds.contains(active[1].id))
        XCTAssertTrue(active[1].neighborIds.contains(active[0].id))
    }

    // MARK: - reduceFacets

    func testReduceRemovesSmallFacet() {
        // 10x10: mostly label 0, with a 2x2 block of label 1 (4 pixels)
        var labels = [Int32](repeating: 0, count: 100)
        labels[0] = 1; labels[1] = 1; labels[10] = 1; labels[11] = 1

        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }

        let centers: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0), // label 0 = red
            SIMD3<Float>(0, 1, 0), // label 1 = green
        ]

        builder.reduceFacets(
            facetMap: &facetMap,
            facets: &facets,
            centers: centers,
            width: 10, height: 10,
            minPixels: 10
        )

        let active = facets.filter { !$0.isDeleted }
        // The 4px facet should be merged, leaving only 1 active facet
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active[0].pixelCount, 100)
    }

    func testReducePreservesLargeFacets() {
        // Two equally sized halves (50px each), minPixels = 10
        var labels = [Int32](repeating: 0, count: 100)
        for y in 5..<10 { for x in 0..<10 { labels[y * 10 + x] = 1 } }

        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 10, height: 10)
        }

        let centers: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 0, 1),
        ]

        builder.reduceFacets(
            facetMap: &facetMap,
            facets: &facets,
            centers: centers,
            width: 10, height: 10,
            minPixels: 10
        )

        let active = facets.filter { !$0.isDeleted }
        XCTAssertEqual(active.count, 2)
    }

    // MARK: - computeLabelPositions

    func testLabelPositionIsInsideFacet() {
        // 20x20 solid color
        let labels = [Int32](repeating: 0, count: 400)
        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 20, height: 20)
        }

        builder.computeLabelPositions(facetMap: facetMap, facets: &facets, width: 20, height: 20)

        let pos = facets[0].labelPosition
        let px = Int(pos.x)
        let py = Int(pos.y)
        XCTAssertTrue(px >= 0 && px < 20)
        XCTAssertTrue(py >= 0 && py < 20)
        // Should be roughly in the center
        XCTAssertTrue(abs(px - 10) <= 2)
        XCTAssertTrue(abs(py - 10) <= 2)
    }

    func testLabelRadiusIsPositive() {
        let labels = [Int32](repeating: 0, count: 400)
        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 20, height: 20)
        }

        builder.computeLabelPositions(facetMap: facetMap, facets: &facets, width: 20, height: 20)

        XCTAssertGreaterThan(facets[0].labelRadius, 0)
    }

    // MARK: - Performance

    func testBuildFacetsPerformance() {
        // Simulate a 900x600 image with 10 color regions (stripes)
        var labels = [Int32](repeating: 0, count: 900 * 600)
        for y in 0..<600 {
            let colorIndex = Int32(y / 60) // 10 horizontal stripes
            for x in 0..<900 {
                labels[y * 900 + x] = colorIndex
            }
        }

        measure {
            let _ = labels.withUnsafeBufferPointer { ptr in
                builder.buildFacets(labels: ptr.baseAddress!, width: 900, height: 600)
            }
        }
    }
}
