import XCTest
@testable import HoehnPhotosOrganizer

final class PBNEdgeCaseTests: XCTestCase {

    let builder = FacetBuilder()

    func testSinglePixelImage() {
        let labels: [Int32] = [0]
        let (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 1, height: 1)
        }
        XCTAssertEqual(facets.count, 1)
        XCTAssertEqual(facets[0].pixelCount, 1)
        XCTAssertEqual(facetMap, [0])
    }

    func testCheckerboardMerge() {
        // 4x4 checkerboard: labels alternate 0 and 1
        var labels = [Int32](repeating: 0, count: 16)
        for y in 0..<4 {
            for x in 0..<4 {
                labels[y * 4 + x] = Int32((x + y) % 2)
            }
        }

        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 4, height: 4)
        }

        // Each pixel is its own facet (no 4-connected neighbors of same color in checkerboard)
        let activeBefore = facets.filter { !$0.isDeleted }.count
        XCTAssertEqual(activeBefore, 16)

        // Merge all facets smaller than 2 pixels
        let centers: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 1, 1),
        ]
        builder.reduceFacets(
            facetMap: &facetMap,
            facets: &facets,
            centers: centers,
            width: 4, height: 4,
            minPixels: 2
        )

        let activeAfter = facets.filter { !$0.isDeleted }.count
        // Should be significantly fewer facets
        XCTAssertLessThan(activeAfter, activeBefore)
    }

    func testAllSameColorNoNeighbors() {
        // 5x5 all same color → 1 facet, 0 neighbors
        let labels = [Int32](repeating: 0, count: 25)
        let (_, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 5, height: 5)
        }
        XCTAssertEqual(facets.count, 1)
        XCTAssertTrue(facets[0].neighborIds.isEmpty)
    }

    func testManySmallRegionsMerge() {
        // 20x20 with random labels 0-3 → many tiny facets
        var labels = [Int32](repeating: 0, count: 400)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<400 {
            labels[i] = Int32.random(in: 0..<4, using: &rng)
        }

        var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
            builder.buildFacets(labels: ptr.baseAddress!, width: 20, height: 20)
        }

        let before = facets.filter { !$0.isDeleted }.count

        let centers: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 1, 0),
        ]

        builder.reduceFacets(
            facetMap: &facetMap,
            facets: &facets,
            centers: centers,
            width: 20, height: 20,
            minPixels: 10
        )

        let after = facets.filter { !$0.isDeleted }.count
        XCTAssertLessThan(after, before, "Facet reduction should decrease total facet count")

        // Verify no pixel is unassigned
        for i in 0..<400 {
            let fid = Int(facetMap[i])
            XCTAssertGreaterThanOrEqual(fid, 0)
            XCTAssertLessThan(fid, facets.count)
        }
    }

    func testLargeImagePerformance() {
        // 1800x1200 with 14 horizontal stripes
        var labels = [Int32](repeating: 0, count: 1800 * 1200)
        for y in 0..<1200 {
            let c = Int32(y * 14 / 1200)
            for x in 0..<1800 {
                labels[y * 1800 + x] = c
            }
        }

        measure {
            var (facetMap, facets) = labels.withUnsafeBufferPointer { ptr in
                builder.buildFacets(labels: ptr.baseAddress!, width: 1800, height: 1200)
            }
            let centers = (0..<14).map { i in
                SIMD3<Float>(Float(i) / 14.0, 0, 0)
            }
            builder.reduceFacets(
                facetMap: &facetMap,
                facets: &facets,
                centers: centers,
                width: 1800, height: 1200,
                minPixels: 20
            )
            builder.computeLabelPositions(
                facetMap: facetMap,
                facets: &facets,
                width: 1800, height: 1200
            )
        }
    }
}
