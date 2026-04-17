import AppKit
import Accelerate

// MARK: - PBNShape

/// A single connected component (shape) within a region.
struct PBNShape: Identifiable {
    let id: Int                    // unique shape ID across all regions
    let regionIndex: Int           // which PBN region this belongs to
    let pixelCount: Int            // number of pixels
    let boundingBox: CGRect        // bounding rectangle
    let centroid: CGPoint          // center of mass
    let perimeterPixels: Int       // boundary pixel count (proxy for perimeter)
    let compactness: Double        // circularity: 4π*area/perimeter² (1.0 = circle)

    /// Whether this shape is "small" (likely noise that could be merged/removed)
    var isSmall: Bool { pixelCount < 100 }

    /// Relative size as percentage of total image
    var sizePercent: Double = 0
}

// MARK: - PBNShapeAnalyzer

final class PBNShapeAnalyzer {

    // MARK: - Analyze All Regions

    /// Run connected-component labeling on all region masks.
    /// Returns shapes grouped by region index.
    func analyzeShapes(
        masks: [[UInt8]],
        width: Int,
        height: Int
    ) -> [Int: [PBNShape]] {
        let totalPixels = width * height
        var result: [Int: [PBNShape]] = [:]
        var nextShapeID = 0

        for regionIndex in 0..<masks.count {
            let (labelMap, shapeCount) = connectedComponents(
                mask: masks[regionIndex],
                width: width,
                height: height
            )

            let shapes = computeShapeProperties(
                labelMap: labelMap,
                shapeCount: shapeCount,
                regionIndex: regionIndex,
                width: width,
                height: height,
                totalPixels: totalPixels,
                startID: nextShapeID
            )

            result[regionIndex] = shapes
            nextShapeID += shapeCount
        }

        return result
    }

    // MARK: - Connected Components (BFS Flood Fill)

    /// Find all shapes in a single binary mask using iterative BFS flood-fill labeling.
    /// Uses 4-connectivity (up/down/left/right, no diagonals).
    func connectedComponents(
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> (labelMap: [Int], shapeCount: Int) {
        let pixelCount = width * height
        // Label 0 means unlabeled / background
        var labelMap = [Int](repeating: 0, count: pixelCount)
        var currentLabel = 0
        var queue = [Int]() // BFS queue of flat indices

        for startIdx in 0..<pixelCount {
            // Skip background pixels and already-labeled pixels
            guard mask[startIdx] > 0, labelMap[startIdx] == 0 else { continue }

            currentLabel += 1
            labelMap[startIdx] = currentLabel
            queue.append(startIdx)

            while !queue.isEmpty {
                let idx = queue.removeLast() // using as stack (DFS-like BFS) for cache locality
                let x = idx % width
                let y = idx / width

                // 4-connected neighbors: up, down, left, right
                let neighbors: [(Int, Int)] = [
                    (x, y - 1),
                    (x, y + 1),
                    (x - 1, y),
                    (x + 1, y)
                ]

                for (nx, ny) in neighbors {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let nIdx = ny * width + nx
                    if mask[nIdx] > 0 && labelMap[nIdx] == 0 {
                        labelMap[nIdx] = currentLabel
                        queue.append(nIdx)
                    }
                }
            }
        }

        return (labelMap: labelMap, shapeCount: currentLabel)
    }

    // MARK: - Shape Properties

    /// Compute properties for each labeled component.
    func computeShapeProperties(
        labelMap: [Int],
        shapeCount: Int,
        regionIndex: Int,
        width: Int,
        height: Int,
        totalPixels: Int,
        startID: Int
    ) -> [PBNShape] {
        guard shapeCount > 0 else { return [] }

        // Accumulators per label (1-indexed)
        var pixelCounts = [Int](repeating: 0, count: shapeCount + 1)
        var sumX = [Int](repeating: 0, count: shapeCount + 1)
        var sumY = [Int](repeating: 0, count: shapeCount + 1)
        var minX = [Int](repeating: Int.max, count: shapeCount + 1)
        var minY = [Int](repeating: Int.max, count: shapeCount + 1)
        var maxX = [Int](repeating: Int.min, count: shapeCount + 1)
        var maxY = [Int](repeating: Int.min, count: shapeCount + 1)
        var perimeterCounts = [Int](repeating: 0, count: shapeCount + 1)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let label = labelMap[idx]
                guard label > 0 else { continue }

                pixelCounts[label] += 1
                sumX[label] += x
                sumY[label] += y

                if x < minX[label] { minX[label] = x }
                if x > maxX[label] { maxX[label] = x }
                if y < minY[label] { minY[label] = y }
                if y > maxY[label] { maxY[label] = y }

                // Check if this pixel is on the perimeter:
                // it has at least one 4-neighbor that is a different label or out of bounds
                let isPerimeter: Bool = {
                    if x == 0 || x == width - 1 || y == 0 || y == height - 1 {
                        return true
                    }
                    if labelMap[idx - 1] != label { return true }       // left
                    if labelMap[idx + 1] != label { return true }       // right
                    if labelMap[idx - width] != label { return true }   // up
                    if labelMap[idx + width] != label { return true }   // down
                    return false
                }()

                if isPerimeter {
                    perimeterCounts[label] += 1
                }
            }
        }

        var shapes: [PBNShape] = []
        shapes.reserveCapacity(shapeCount)

        for label in 1...shapeCount {
            let count = pixelCounts[label]
            guard count > 0 else { continue }

            let cx = Double(sumX[label]) / Double(count)
            let cy = Double(sumY[label]) / Double(count)
            let perim = perimeterCounts[label]

            // compactness = 4π * area / perimeter²
            let compactness: Double
            if perim > 0 {
                compactness = min((4.0 * .pi * Double(count)) / (Double(perim) * Double(perim)), 1.0)
            } else {
                compactness = 1.0
            }

            let sizePercent = totalPixels > 0 ? Double(count) / Double(totalPixels) * 100.0 : 0

            var shape = PBNShape(
                id: startID + label - 1,
                regionIndex: regionIndex,
                pixelCount: count,
                boundingBox: CGRect(
                    x: minX[label],
                    y: minY[label],
                    width: maxX[label] - minX[label] + 1,
                    height: maxY[label] - minY[label] + 1
                ),
                centroid: CGPoint(x: cx, y: cy),
                perimeterPixels: perim,
                compactness: compactness
            )
            shape.sizePercent = sizePercent
            shapes.append(shape)
        }

        return shapes
    }

    // MARK: - Shape Mask

    /// Generate a mask for a single shape (255 where shape exists, 0 elsewhere).
    func shapeMask(
        labelMap: [Int],
        shapeLabel: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        let count = width * height
        var output = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            if labelMap[i] == shapeLabel {
                output[i] = 255
            }
        }
        return output
    }

    // MARK: - Remove Small Shapes

    /// Remove small shapes by merging them into the nearest neighboring region.
    /// Returns updated masks with small components reassigned.
    func removeSmallShapes(
        masks: inout [[UInt8]],
        width: Int,
        height: Int,
        minPixels: Int
    ) {
        let regionCount = masks.count
        guard regionCount > 1 else { return }

        // Build a combined region-index map: for each pixel, which region owns it
        let pixelCount = width * height
        var regionMap = [Int](repeating: -1, count: pixelCount)
        for r in 0..<regionCount {
            for i in 0..<pixelCount {
                if masks[r][i] > 0 {
                    regionMap[i] = r
                }
            }
        }

        // Process each region independently
        for regionIndex in 0..<regionCount {
            let (labelMap, shapeCount) = connectedComponents(
                mask: masks[regionIndex],
                width: width,
                height: height
            )
            guard shapeCount > 0 else { continue }

            // Count pixels per label
            var labelCounts = [Int](repeating: 0, count: shapeCount + 1)
            for label in labelMap where label > 0 {
                labelCounts[label] += 1
            }

            // For each small component, find the best neighboring region to absorb it
            for label in 1...shapeCount {
                guard labelCounts[label] < minPixels else { continue }

                // Count neighboring region occurrences (excluding current region and background)
                var neighborRegionCounts = [Int: Int]()

                for y in 0..<height {
                    for x in 0..<width {
                        let idx = y * width + x
                        guard labelMap[idx] == label else { continue }

                        let neighbors: [(Int, Int)] = [
                            (x, y - 1), (x, y + 1), (x - 1, y), (x + 1, y)
                        ]

                        for (nx, ny) in neighbors {
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let nIdx = ny * width + nx
                            let neighborRegion = regionMap[nIdx]
                            if neighborRegion >= 0 && neighborRegion != regionIndex {
                                neighborRegionCounts[neighborRegion, default: 0] += 1
                            }
                        }
                    }
                }

                // Pick the most common neighboring region
                guard let targetRegion = neighborRegionCounts.max(by: { $0.value < $1.value })?.key else {
                    continue
                }

                // Reassign: remove from current region, add to target
                for i in 0..<pixelCount {
                    if labelMap[i] == label {
                        masks[regionIndex][i] = 0
                        masks[targetRegion][i] = 255
                        regionMap[i] = targetRegion
                    }
                }
            }
        }
    }

    // MARK: - Smooth Boundaries (Morphological Close)

    /// Smooth region boundaries using morphological close (dilate then erode).
    func smoothBoundaries(
        masks: inout [[UInt8]],
        width: Int,
        height: Int,
        kernelSize: Int
    ) {
        let kernel = max(3, min(kernelSize | 1, 7)) // ensure odd: 3, 5, or 7
        let regionCount = masks.count

        let structElem = [UInt8](repeating: 1, count: kernel * kernel)

        for regionIndex in 0..<regionCount {
            var temp = [UInt8](repeating: 0, count: width * height)
            var output = [UInt8](repeating: 0, count: width * height)

            masks[regionIndex].withUnsafeMutableBufferPointer { srcPtr in
                temp.withUnsafeMutableBufferPointer { tmpPtr in
                    output.withUnsafeMutableBufferPointer { outPtr in
                        var srcBuf = vImage_Buffer(
                            data: srcPtr.baseAddress!,
                            height: vImagePixelCount(height),
                            width: vImagePixelCount(width),
                            rowBytes: width
                        )
                        var tmpBuf = vImage_Buffer(
                            data: tmpPtr.baseAddress!,
                            height: vImagePixelCount(height),
                            width: vImagePixelCount(width),
                            rowBytes: width
                        )
                        var outBuf = vImage_Buffer(
                            data: outPtr.baseAddress!,
                            height: vImagePixelCount(height),
                            width: vImagePixelCount(width),
                            rowBytes: width
                        )

                        // Dilate (max filter): source -> temp
                        vImageDilate_Planar8(
                            &srcBuf,
                            &tmpBuf,
                            0, 0,
                            structElem,
                            vImagePixelCount(kernel),
                            vImagePixelCount(kernel),
                            vImage_Flags(kvImageNoFlags)
                        )

                        // Erode (min filter): temp -> output
                        vImageErode_Planar8(
                            &tmpBuf,
                            &outBuf,
                            0, 0,
                            structElem,
                            vImagePixelCount(kernel),
                            vImagePixelCount(kernel),
                            vImage_Flags(kvImageNoFlags)
                        )
                    }
                }
            }

            masks[regionIndex] = output
        }
    }

    // MARK: - Render Shape Map

    /// Render a color-coded visualization where each shape gets a unique color.
    /// Uses golden-angle hue spacing for maximum visual distinction.
    func renderShapeMap(
        masks: [[UInt8]],
        width: Int,
        height: Int
    ) -> NSImage {
        let pixelCount = width * height

        // First, run connected components on all regions to assign global shape IDs
        var globalLabelMap = [Int](repeating: 0, count: pixelCount)
        var totalShapes = 0

        for regionIndex in 0..<masks.count {
            let (labelMap, shapeCount) = connectedComponents(
                mask: masks[regionIndex],
                width: width,
                height: height
            )

            for i in 0..<pixelCount {
                if labelMap[i] > 0 {
                    globalLabelMap[i] = totalShapes + labelMap[i]
                }
            }
            totalShapes += shapeCount
        }

        // Build RGBA pixel data
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)

        for i in 0..<pixelCount {
            let shapeID = globalLabelMap[i]
            if shapeID > 0 {
                // Golden-angle hue spacing: hue = shapeID * 137.508° mod 360
                let hue = Double(shapeID) * 137.508.truncatingRemainder(dividingBy: 360.0)
                let normalizedHue = hue.truncatingRemainder(dividingBy: 360.0) / 360.0
                let (r, g, b) = hsbToRGB(h: normalizedHue, s: 0.75, b: 0.9)

                rgba[i * 4]     = UInt8(clamping: Int(r * 255))
                rgba[i * 4 + 1] = UInt8(clamping: Int(g * 255))
                rgba[i * 4 + 2] = UInt8(clamping: Int(b * 255))
                rgba[i * 4 + 3] = 255
            } else {
                // Background: transparent black
                rgba[i * 4]     = 0
                rgba[i * 4 + 1] = 0
                rgba[i * 4 + 2] = 0
                rgba[i * 4 + 3] = 255
            }
        }

        return nsImageFromRGBA(rgba, width: width, height: height)
    }

    // MARK: - Private Helpers

    /// Convert HSB (all 0-1) to RGB (all 0-1).
    private func hsbToRGB(h: Double, s: Double, b: Double) -> (Double, Double, Double) {
        let c = b * s
        let hPrime = h * 6.0
        let x = c * (1.0 - abs(hPrime.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = b - c

        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hPrime) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }

        return (r1 + m, g1 + m, b1 + m)
    }

    /// Create an NSImage from raw RGBA pixel data.
    private func nsImageFromRGBA(_ rgba: [UInt8], width: Int, height: Int) -> NSImage {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4

        guard let providerRef = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: providerRef,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
