import Foundation
import simd

// MARK: - PBNFacet

/// Lightweight facet info for label placement — built AFTER merge, not before.
struct PBNFacet {
    let id: Int
    let colorIndex: Int
    var pixelCount: Int
    var bbox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    var borderPixelCount: Int
    var neighborIds: Set<Int>
    var labelPosition: CGPoint
    var labelRadius: CGFloat
    var isDeleted: Bool = false
}

// MARK: - FacetBuilder

final class FacetBuilder {

    // MARK: - Fast Small Region Elimination

    /// Eliminate small connected components directly on the labels buffer.
    /// For each component smaller than minPixels, reassign its pixels to the
    /// most common neighboring label. Runs in a single pass with a reusable flood-fill.
    /// Modifies `labels` in place. Returns the number of regions eliminated.
    @discardableResult
    func eliminateSmallRegions(labels: UnsafeMutablePointer<Int32>, width: Int, height: Int, minPixels: Int) -> Int {
        let pixelCount = width * height
        var visited = [Bool](repeating: false, count: pixelCount)
        var stack = [Int]()
        stack.reserveCapacity(min(pixelCount, 4096))
        var componentPixels = [Int]()
        componentPixels.reserveCapacity(minPixels * 2)
        var eliminated = 0

        for startIdx in 0..<pixelCount {
            guard !visited[startIdx] else { continue }

            let colorLabel = labels[startIdx]
            componentPixels.removeAll(keepingCapacity: true)

            // Flood fill to find this connected component
            stack.append(startIdx)
            visited[startIdx] = true

            while !stack.isEmpty {
                let idx = stack.removeLast()
                componentPixels.append(idx)

                let x = idx % width
                let y = idx / width

                // Check 4 neighbors
                if x > 0 {
                    let n = idx - 1
                    if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) }
                }
                if x < width - 1 {
                    let n = idx + 1
                    if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) }
                }
                if y > 0 {
                    let n = idx - width
                    if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) }
                }
                if y < height - 1 {
                    let n = idx + width
                    if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) }
                }

                // Early exit: if component already exceeds threshold, skip counting the rest
                if componentPixels.count >= minPixels {
                    // Drain the remaining flood fill without storing pixels
                    while !stack.isEmpty {
                        let idx2 = stack.removeLast()
                        let x2 = idx2 % width
                        let y2 = idx2 / width
                        if x2 > 0 { let n = idx2 - 1; if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) } }
                        if x2 < width - 1 { let n = idx2 + 1; if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) } }
                        if y2 > 0 { let n = idx2 - width; if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) } }
                        if y2 < height - 1 { let n = idx2 + width; if !visited[n] && labels[n] == colorLabel { visited[n] = true; stack.append(n) } }
                    }
                    break
                }
            }

            // If small, find the most common neighbor label and reassign
            if componentPixels.count < minPixels {
                var neighborCounts = [Int32: Int]()
                for pIdx in componentPixels {
                    let x = pIdx % width
                    let y = pIdx / width
                    if x > 0 { let nl = labels[pIdx - 1]; if nl != colorLabel { neighborCounts[nl, default: 0] += 1 } }
                    if x < width - 1 { let nl = labels[pIdx + 1]; if nl != colorLabel { neighborCounts[nl, default: 0] += 1 } }
                    if y > 0 { let nl = labels[pIdx - width]; if nl != colorLabel { neighborCounts[nl, default: 0] += 1 } }
                    if y < height - 1 { let nl = labels[pIdx + width]; if nl != colorLabel { neighborCounts[nl, default: 0] += 1 } }
                }
                if let bestLabel = neighborCounts.max(by: { $0.value < $1.value })?.key {
                    for pIdx in componentPixels {
                        labels[pIdx] = bestLabel
                    }
                    eliminated += 1
                }
            }
        }
        return eliminated
    }

    // MARK: - Build Facets (lightweight, post-merge)

    /// Build facets from the (already merged) label buffer. Only used for label placement.
    /// Much faster than pre-merge because there are far fewer facets.
    func buildFacets(labels: UnsafePointer<Int32>, width: Int, height: Int) -> (facetMap: [Int32], facets: [PBNFacet]) {
        let totalPixels = width * height
        var facetMap = [Int32](repeating: -1, count: totalPixels)
        var facets: [PBNFacet] = []
        var facetId: Int32 = 0
        var stack = [Int]()
        stack.reserveCapacity(1024)

        for startIdx in 0..<totalPixels {
            guard facetMap[startIdx] == -1 else { continue }

            let colorIndex = Int(labels[startIdx])
            var count = 0
            var borderCount = 0
            let startX = startIdx % width
            let startY = startIdx / width
            var minX = startX, minY = startY, maxX = startX, maxY = startY
            // For centroid
            var sumX: Int = 0, sumY: Int = 0

            stack.append(startIdx)
            facetMap[startIdx] = facetId

            while !stack.isEmpty {
                let idx = stack.removeLast()
                count += 1
                let cx = idx % width
                let cy = idx / width
                sumX += cx
                sumY += cy
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }

                var isBorder = false
                if cx > 0 { let n = idx-1; if labels[n] == Int32(colorIndex) { if facetMap[n] == -1 { facetMap[n] = facetId; stack.append(n) } } else { isBorder = true } } else { isBorder = true }
                if cx < width-1 { let n = idx+1; if labels[n] == Int32(colorIndex) { if facetMap[n] == -1 { facetMap[n] = facetId; stack.append(n) } } else { isBorder = true } } else { isBorder = true }
                if cy > 0 { let n = idx-width; if labels[n] == Int32(colorIndex) { if facetMap[n] == -1 { facetMap[n] = facetId; stack.append(n) } } else { isBorder = true } } else { isBorder = true }
                if cy < height-1 { let n = idx+width; if labels[n] == Int32(colorIndex) { if facetMap[n] == -1 { facetMap[n] = facetId; stack.append(n) } } else { isBorder = true } } else { isBorder = true }
                if isBorder { borderCount += 1 }
            }

            let facet = PBNFacet(
                id: Int(facetId),
                colorIndex: colorIndex,
                pixelCount: count,
                bbox: (minX, minY, maxX, maxY),
                borderPixelCount: borderCount,
                neighborIds: [],
                labelPosition: count > 0 ? CGPoint(x: CGFloat(sumX) / CGFloat(count), y: CGFloat(sumY) / CGFloat(count)) : .zero,
                labelRadius: CGFloat(min(maxX - minX, maxY - minY)) / 4.0
            )
            facets.append(facet)
            facetId += 1
        }

        return (facetMap, facets)
    }

    // MARK: - Reduce (legacy compatibility — delegates to eliminateSmallRegions)

    func reduceFacets(
        facetMap: inout [Int32],
        facets: inout [PBNFacet],
        centers: [SIMD3<Float>],
        width: Int,
        height: Int,
        minPixels: Int
    ) {
        // No-op: use eliminateSmallRegions on the labels buffer instead
    }

    // MARK: - Label Positions (Chamfer distance transform)

    func computeLabelPositions(facetMap: [Int32], facets: inout [PBNFacet], width: Int, height: Int) {
        for i in facets.indices where !facets[i].isDeleted && facets[i].pixelCount > 100 {
            let facetId = Int32(facets[i].id)
            let bbox = facets[i].bbox
            let bw = bbox.maxX - bbox.minX + 1
            let bh = bbox.maxY - bbox.minY + 1
            guard bw > 2, bh > 2 else { continue }

            var dist = [Int](repeating: 0, count: bw * bh)

            for ly in 0..<bh {
                for lx in 0..<bw {
                    let gx = bbox.minX + lx
                    let gy = bbox.minY + ly
                    let gIdx = gy * width + gx
                    if facetMap[gIdx] != facetId {
                        dist[ly * bw + lx] = 0
                    } else {
                        var isBorder = gx == 0 || gx == width - 1 || gy == 0 || gy == height - 1
                        if !isBorder {
                            if facetMap[gIdx - 1] != facetId || facetMap[gIdx + 1] != facetId ||
                               facetMap[gIdx - width] != facetId || facetMap[gIdx + width] != facetId {
                                isBorder = true
                            }
                        }
                        dist[ly * bw + lx] = isBorder ? 0 : 10000
                    }
                }
            }

            // Forward pass
            for ly in 0..<bh {
                for lx in 0..<bw {
                    let idx = ly * bw + lx
                    if dist[idx] == 0 { continue }
                    var d = dist[idx]
                    if lx > 0 { d = min(d, dist[idx - 1] + 1) }
                    if ly > 0 { d = min(d, dist[(ly - 1) * bw + lx] + 1) }
                    dist[idx] = d
                }
            }
            // Backward pass
            for ly in stride(from: bh - 1, through: 0, by: -1) {
                for lx in stride(from: bw - 1, through: 0, by: -1) {
                    let idx = ly * bw + lx
                    if dist[idx] == 0 { continue }
                    var d = dist[idx]
                    if lx < bw - 1 { d = min(d, dist[idx + 1] + 1) }
                    if ly < bh - 1 { d = min(d, dist[(ly + 1) * bw + lx] + 1) }
                    dist[idx] = d
                }
            }

            var maxDist = 0
            var bestLocal = (x: bw / 2, y: bh / 2)
            for ly in 0..<bh {
                for lx in 0..<bw {
                    let d = dist[ly * bw + lx]
                    if d > maxDist { maxDist = d; bestLocal = (lx, ly) }
                }
            }

            facets[i].labelPosition = CGPoint(x: CGFloat(bbox.minX + bestLocal.x), y: CGFloat(bbox.minY + bestLocal.y))
            facets[i].labelRadius = CGFloat(maxDist)
        }
    }
}
