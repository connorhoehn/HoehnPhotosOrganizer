import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate
import Metal
import simd
import os.log

// MARK: - PaintByNumbersRenderError

enum PaintByNumbersRenderError: Error, LocalizedError {
    case failedToCreateCGImage
    case failedToCreatePixelBuffer
    case failedToRenderOutput
    case invalidRegionIndex(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failedToCreateCGImage:       return "Could not create CGImage from source."
        case .failedToCreatePixelBuffer:   return "Could not allocate pixel buffer."
        case .failedToRenderOutput:        return "Failed to produce output image."
        case .invalidRegionIndex(let idx): return "Region index \(idx) is out of range."
        case .cancelled:                   return "Render was cancelled."
        }
    }
}

// MARK: - PaintByNumbersRenderer

private let pbnLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HoehnPhotosOrganizer", category: "PBN")

final class PaintByNumbersRenderer {

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let facetBuilder = FacetBuilder()

    // MARK: - Metal Region Map Cache

    /// Cached region map texture (R8Uint) to avoid regenerating when only display mode changes.
    private var cachedRegionMap: MTLTexture?
    /// Identity of the source image + thresholds used to generate the cached region map.
    private var cachedRegionMapKey: String?

    /// Read a single region index from a region map texture at the given point.
    /// Coordinates are in pixel space (0,0 at top-left).
    /// Returns nil if point is out of bounds or texture is unavailable.
    func readRegionIndex(from texture: MTLTexture, at point: CGPoint) -> UInt8? {
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, x < texture.width, y >= 0, y < texture.height else { return nil }

        var pixel: UInt8 = 0
        texture.getBytes(
            &pixel,
            bytesPerRow: texture.width,  // R8Uint = 1 byte per pixel
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return pixel
    }

    /// Access the currently cached region map (for hover detection).
    var currentRegionMap: MTLTexture? { cachedRegionMap }

    // MARK: - Metal GPU Render

    /// GPU-accelerated render via Metal compute kernels.
    /// Returns the composite image and optionally the region map texture for hover detection.
    func renderMetal(
        source: NSImage,
        config: PBNConfig,
        displayMode: PBNDisplayMode,
        highlightedRegion: Int? = nil,
        selectedRegions: Set<Int>? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> (image: NSImage, regionMap: MTLTexture?) {
        try Task.checkCancellation()

        let renderStart = CFAbsoluteTimeGetCurrent()

        guard let metal = MetalImageProcessor.shared else {
            pbnLog.warning("[PBN-Metal] MetalImageProcessor not available, falling back to CPU")
            let cpuResult = try await render(
                source: source,
                config: config,
                displayMode: displayMode,
                highlightedRegion: highlightedRegion,
                progress: progress
            )
            return (cpuResult, nil)
        }

        // For original mode, just pass through
        if displayMode == .original {
            progress(1.0)
            return (source, nil)
        }

        let thresholds = config.thresholds
        let regionCount = thresholds.regionCount
        let expandedColors = config.palette.expandedColors(toCount: regionCount)
        let palette = PBNPalette(id: config.palette.id, name: config.palette.name, colors: expandedColors)

        pbnLog.info("[PBN-Metal] Render start: regions=\(regionCount), mode=\(String(describing: displayMode))")

        // Step 1: Source -> Metal texture
        progress(0.05)
        guard let inputTexture = metal.textureFromImage(source) else {
            throw PaintByNumbersRenderError.failedToCreateCGImage
        }
        let width = inputTexture.width
        let height = inputTexture.height
        var stepStart = CFAbsoluteTimeGetCurrent()

        // Build a cache key from source dimensions + thresholds + blur + posterize
        let cacheKey = "\(width)x\(height)_\(thresholds.thresholds)_\(config.blurRadius)_\(config.posterizationLevels)"

        // Check if we can reuse cached region map
        var regionMap: MTLTexture
        if let cached = cachedRegionMap, cachedRegionMapKey == cacheKey {
            regionMap = cached
            pbnLog.debug("[PBN-Metal] Reusing cached region map")
            progress(0.40)
        } else {
            // Desaturate on GPU (texture-to-texture, no NSImage round-trip)
            guard let grayTexture = metal.desaturateTexture(inputTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            stepStart = logElapsed("Metal desaturate (texture)", since: stepStart)
            progress(0.15)

            try Task.checkCancellation()

            // Optional blur on GPU (texture-to-texture)
            var classifyInput = grayTexture
            if config.blurRadius > 0 {
                guard let blurred = metal.gaussianBlurTexture(grayTexture, sigma: config.blurRadius) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                classifyInput = blurred
                stepStart = logElapsed("Metal blur (texture)", since: stepStart)
            }
            progress(0.25)

            // Classify regions
            let thresholdValues = thresholds.thresholds.map { UInt32($0) }
            guard let classifiedMap = metal.pbnClassifyRegions(
                grayscale: classifyInput,
                thresholds: thresholdValues,
                regionCount: UInt32(regionCount)
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            stepStart = logElapsed("Metal classify regions", since: stepStart)
            progress(0.40)

            regionMap = classifiedMap
            cachedRegionMap = classifiedMap
            cachedRegionMapKey = cacheKey
        }

        try Task.checkCancellation()

        // Now dispatch based on display mode
        let result: NSImage

        switch displayMode {
        case .original:
            fatalError("Handled above")

        case .colorFill:
            // Use existing threshold_map kernel for color fill (it already does exactly this)
            let thresholdInts = thresholds.thresholds
            if let selection = selectedRegions, !selection.isEmpty {
                // Dim unselected regions by modifying palette colors, then render with contour lines around selected
                var dimmedColors: [[Double]] = expandedColors.enumerated().map { (i, c) in
                    if selection.contains(i) {
                        return [c.red * 255, c.green * 255, c.blue * 255]
                    } else {
                        let gray = 0.15
                        return [(c.red * 0.3 + gray * 0.7) * 255,
                                (c.green * 0.3 + gray * 0.7) * 255,
                                (c.blue * 0.3 + gray * 0.7) * 255]
                    }
                }
                guard let colorFillImage = metal.thresholdMap(source, thresholds: thresholdInts, colors: dimmedColors) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                // Add contour lines around selected regions for visual distinction
                let lineNS = config.contourSettings.lineColor
                let lineColor = SIMD4<Float>(
                    Float(lineNS.red), Float(lineNS.green), Float(lineNS.blue), 1.0
                )
                let selectionLineWeight = UInt32(max(2, Int(config.contourSettings.lineWeight) + 1))
                guard let contourTexture = metal.pbnTintAndBoundary(
                    regionMap: regionMap,
                    paletteColors: [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: regionCount),
                    lineColor: lineColor,
                    lineWeight: selectionLineWeight,
                    width: width,
                    height: height
                ) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                guard let contourImage = metal.imageFromTexture(contourTexture) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                guard let composited = metal.multiplyBlend(base: colorFillImage, top: contourImage) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                result = composited
            } else {
                let colorArrays: [[Double]] = expandedColors.map { [$0.red * 255, $0.green * 255, $0.blue * 255] }
                guard let colorFillImage = metal.thresholdMap(source, thresholds: thresholdInts, colors: colorArrays) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                result = colorFillImage
            }
            stepStart = logElapsed("Metal color fill (threshold_map)", since: stepStart)

        case .contourOnly, .numbered, .colorWithContour:
            // Build tint colors (pre-blended 20% tint over white)
            var paletteColors: [SIMD4<Float>] = expandedColors.map { c in
                let r = Float(c.red * 0.2 + 1.0 * 0.8)
                let g = Float(c.green * 0.2 + 1.0 * 0.8)
                let b = Float(c.blue * 0.2 + 1.0 * 0.8)
                return SIMD4<Float>(r, g, b, 1.0)
            }

            // For contourOnly, use white tints (all regions white, only lines show)
            if displayMode == .contourOnly {
                paletteColors = [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: regionCount)
            }

            let lineNS = config.contourSettings.lineColor
            let lineColor = SIMD4<Float>(
                Float(lineNS.red), Float(lineNS.green), Float(lineNS.blue), 1.0
            )
            let lineWeight = UInt32(max(1, Int(config.contourSettings.lineWeight)))

            guard let tintTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: paletteColors,
                lineColor: lineColor,
                lineWeight: lineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            stepStart = logElapsed("Metal tint+boundary", since: stepStart)
            progress(0.70)

            guard let tintImage = metal.imageFromTexture(tintTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }

            if displayMode == .numbered && config.contourSettings.showNumbers {
                // Draw number labels via CoreText on CPU (same as existing)
                result = drawNumberLabelsOnImage(
                    tintImage,
                    regionMap: regionMap,
                    palette: palette,
                    settings: config.contourSettings,
                    width: width,
                    height: height
                )
                stepStart = logElapsed("CPU number labels", since: stepStart)
            } else if displayMode == .colorWithContour {
                // Color fill + contour composite: get color fill, then multiply blend with tint
                let thresholdInts = thresholds.thresholds
                var colorArrays: [[Double]] = expandedColors.map { [$0.red * 255, $0.green * 255, $0.blue * 255] }
                if let selection = selectedRegions, !selection.isEmpty {
                    for i in 0..<colorArrays.count {
                        if !selection.contains(i) {
                            let gray = 0.15
                            colorArrays[i] = [(expandedColors[i].red * 0.3 + gray * 0.7) * 255,
                                               (expandedColors[i].green * 0.3 + gray * 0.7) * 255,
                                               (expandedColors[i].blue * 0.3 + gray * 0.7) * 255]
                        }
                    }
                }
                guard let colorFillImage = metal.thresholdMap(source, thresholds: thresholdInts, colors: colorArrays) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                // Use contour-only tint (white background + lines) and multiply-blend over color fill
                let contourPaletteColors = [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: regionCount)
                guard let contourTexture = metal.pbnTintAndBoundary(
                    regionMap: regionMap,
                    paletteColors: contourPaletteColors,
                    lineColor: lineColor,
                    lineWeight: lineWeight,
                    width: width,
                    height: height
                ) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                guard let contourImage = metal.imageFromTexture(contourTexture) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                guard let composited = metal.multiplyBlend(base: colorFillImage, top: contourImage) else {
                    throw PaintByNumbersRenderError.failedToRenderOutput
                }
                result = composited
                stepStart = logElapsed("Metal color+contour composite", since: stepStart)
            } else {
                result = tintImage
            }

        case .highlightRegion:
            // Build the base tinted image, then apply hover highlight
            let paletteColors: [SIMD4<Float>] = expandedColors.map { c in
                let r = Float(c.red)
                let g = Float(c.green)
                let b = Float(c.blue)
                return SIMD4<Float>(r, g, b, 1.0)
            }

            let lineNS = config.contourSettings.lineColor
            let lineColor = SIMD4<Float>(
                Float(lineNS.red), Float(lineNS.green), Float(lineNS.blue), 1.0
            )
            let lineWeight = UInt32(max(1, Int(config.contourSettings.lineWeight)))

            guard let baseTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: paletteColors,
                lineColor: lineColor,
                lineWeight: lineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }

            guard let highlightTexture = metal.pbnHoverHighlight(
                regionMap: regionMap,
                baseImage: baseTexture,
                highlightedRegion: UInt32(highlightedRegion ?? 0),
                dimAlpha: 0.3
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }

            guard let highlightImage = metal.imageFromTexture(highlightTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = highlightImage
            stepStart = logElapsed("Metal highlight region", since: stepStart)

        case .sideBySide:
            // Color fill for processed side
            let thresholdInts = thresholds.thresholds
            let colorArrays: [[Double]] = expandedColors.map { [$0.red * 255, $0.green * 255, $0.blue * 255] }
            guard let colorFillImage = metal.thresholdMap(source, thresholds: thresholdInts, colors: colorArrays) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = buildSideBySide(original: source, processed: colorFillImage)
            stepStart = logElapsed("Metal side-by-side", since: stepStart)
        }

        progress(1.0)
        pbnLog.info("[PBN-Metal] Render complete (\(String(describing: displayMode))) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderStart))s total")
        return (result, regionMap)
    }

    // MARK: - Metal V2 GPU K-Means Pipeline

    /// GPU-accelerated render using the full k-means pipeline:
    /// bilateral pre-filter -> k-means quantize -> strip cleanup -> facet merge -> region map -> tint+boundary -> labels.
    /// Returns the rendered image, an optional region map texture for hover detection, and the facet array.
    func renderMetalV2(
        source: NSImage,
        config: PBNConfig,
        displayMode: PBNDisplayMode,
        highlightedRegion: Int? = nil,
        selectedRegions: Set<Int>? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> (image: NSImage, regionMap: MTLTexture?, facets: [PBNFacet], numberAssignment: PBNNumberAssignment?) {
        try Task.checkCancellation()

        let renderStart = CFAbsoluteTimeGetCurrent()

        // (a) Guard for Metal availability, fall back to old render() if unavailable
        guard let metal = MetalImageProcessor.shared else {
            pbnLog.warning("[PBN-V2] MetalImageProcessor not available, falling back to CPU")
            let cpuResult = try await render(
                source: source,
                config: config,
                displayMode: displayMode,
                highlightedRegion: highlightedRegion,
                progress: progress
            )
            return (cpuResult, nil, [], nil)
        }

        // (b) Original mode passthrough
        if displayMode == .original {
            progress(1.0)
            return (source, nil, [], nil)
        }

        let numColors = config.palette.colors.count
        var stepStart = CFAbsoluteTimeGetCurrent()

        pbnLog.info("[PBN-V2] Render start: numColors=\(numColors), mode=\(String(describing: displayMode)), kMeansIter=\(config.kMeansIterations)")

        // (c) Pre-filter: bilateral smoothing to reduce noise while preserving edges
        progress(0.05)
        var filtered = source
        if config.bilateralPreFilter {
            let diameter = config.bilateralRadius * 2 + 1
            if let bilateralResult = metal.bilateralFilter(
                source,
                diameter: diameter,
                sigmaColor: Double(config.bilateralRadius) * 3,
                sigmaSpace: Double(config.bilateralRadius)
            ) {
                filtered = bilateralResult
            }
            stepStart = logElapsed("V2 bilateral pre-filter", since: stepStart)
        }
        progress(0.10)

        try Task.checkCancellation()

        // (d) K-means quantize
        // When restricting to palette, cap numColors to palette size (no point clustering
        // into 17 groups if they'll all snap to 4 palette colors anyway)
        let restrictColors: [SIMD3<Float>]?
        let effectiveNumColors: Int
        if config.restrictToPalette {
            restrictColors = config.palette.colors.map { SIMD3<Float>(Float($0.red), Float($0.green), Float($0.blue)) }
            effectiveNumColors = min(numColors, config.palette.colors.count)
        } else {
            restrictColors = nil
            effectiveNumColors = numColors
        }

        guard let kmeansResult = metal.kmeansQuantizeWithLabels(
            filtered,
            numColors: effectiveNumColors,
            iterations: config.kMeansIterations,
            restrictPalette: restrictColors
        ) else {
            throw PaintByNumbersRenderError.failedToRenderOutput
        }
        stepStart = logElapsed("V2 k-means quantize", since: stepStart)
        progress(0.30)

        try Task.checkCancellation()

        // (e) Narrow strip cleanup
        let cleanedLabels: MTLBuffer
        if config.narrowStripPasses > 0 {
            guard let cleaned = metal.narrowStripCleanup(
                labels: kmeansResult.labelsBuffer,
                centers: kmeansResult.centersBuffer,
                width: kmeansResult.width,
                height: kmeansResult.height,
                numColors: kmeansResult.numColors,
                passes: config.narrowStripPasses
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            cleanedLabels = cleaned
        } else {
            cleanedLabels = kmeansResult.labelsBuffer
        }
        stepStart = logElapsed("V2 narrow strip cleanup", since: stepStart)
        progress(0.40)

        try Task.checkCancellation()

        let width = kmeansResult.width
        let height = kmeansResult.height
        let pixelCount = width * height

        // (f) Eliminate small regions directly on the labels buffer (fast, no facet overhead)
        let labelsPtr = cleanedLabels.contents().bindMemory(to: Int32.self, capacity: pixelCount)
        let eliminated = facetBuilder.eliminateSmallRegions(
            labels: labelsPtr, width: width, height: height, minPixels: config.minFacetPixels
        )
        stepStart = logElapsed("V2 small region elimination (\(eliminated) removed)", since: stepStart)

        // (g) Build facets from merged labels (lightweight — only for label placement)
        var (facetMap, facets) = facetBuilder.buildFacets(labels: labelsPtr, width: width, height: height)
        stepStart = logElapsed("V2 facet build (\(facets.count) facets)", since: stepStart)

        // Chamfer distance label positions — only needed for modes that draw numbers
        let needsLabels = (displayMode == .numbered || displayMode == .contourOnly || displayMode == .colorWithContour)
        if needsLabels {
            facetBuilder.computeLabelPositions(facetMap: facetMap, facets: &facets, width: width, height: height)
            stepStart = logElapsed("V2 label positions (\(facets.count) facets)", since: stepStart)
        } else {
            pbnLog.debug("[PBN-V2] Skipping label positions for \(String(describing: displayMode))")
        }
        progress(0.55)

        try Task.checkCancellation()

        // (h) Upload modified facet map back to GPU and build region map
        // The facet map contains facet IDs; we need to convert back to color indices for the region map
        let labelsBufferLength = pixelCount * MemoryLayout<Int32>.stride
        guard let uploadBuffer = metal.device.makeBuffer(length: labelsBufferLength, options: .storageModeManaged) else {
            throw PaintByNumbersRenderError.failedToCreatePixelBuffer
        }
        let uploadPtr = uploadBuffer.contents().bindMemory(to: Int32.self, capacity: pixelCount)
        for i in 0..<pixelCount {
            let facetId = Int(facetMap[i])
            if facetId >= 0, facetId < facets.count, !facets[facetId].isDeleted {
                uploadPtr[i] = Int32(facets[facetId].colorIndex)
            } else {
                uploadPtr[i] = 0
            }
        }
        uploadBuffer.didModifyRange(0..<labelsBufferLength)

        guard let regionMap = metal.labelsToRegionMap(labels: uploadBuffer, width: width, height: height) else {
            throw PaintByNumbersRenderError.failedToRenderOutput
        }
        stepStart = logElapsed("V2 labels -> region map", since: stepStart)
        progress(0.65)

        // (i) Cache the region map
        let cacheKey = "v2_\(width)x\(height)_\(numColors)_\(config.kMeansIterations)_\(config.minFacetPixels)_\(config.narrowStripPasses)"
        cachedRegionMap = regionMap
        cachedRegionMapKey = cacheKey

        try Task.checkCancellation()

        // Read k-means centers from GPU for palette colors
        let centersPtr = kmeansResult.centersBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: numColors)
        let centers = (0..<numColors).map { centersPtr[$0] }

        // Compute color mixing recipes from k-means centers
        let numberAssignment: PBNNumberAssignment? = {
            let recipeBuilder = PBNRecipeBuilder()
            let centerTuples = (0..<numColors).map { i in
                (r: Double(centers[i].x), g: Double(centers[i].y), b: Double(centers[i].z))
            }
            // Build coverage map from facets
            var facetCoverage: [Int: Double] = [:]
            let totalPixels = Double(width * height)
            for facet in facets where !facet.isDeleted {
                facetCoverage[facet.colorIndex, default: 0] += Double(facet.pixelCount) / totalPixels * 100
            }
            return recipeBuilder.assignNumbers(
                centers: centerTuples,
                palette: config.palette,
                facetCoverage: facetCoverage
            )
        }()

        // Build palette colors as SIMD4<Float> from k-means centers
        let expandedColors: [SIMD4<Float>] = (0..<numColors).map { i in
            let c = centers[i]
            return SIMD4<Float>(c.x, c.y, c.z, 1.0)
        }

        let lineNS = config.contourSettings.lineColor
        let blackColor = SIMD4<Float>(Float(lineNS.red), Float(lineNS.green), Float(lineNS.blue), 1.0)
        let clearColor = SIMD4<Float>(0, 0, 0, 0)
        let lineWeight = UInt32(max(1, Int(config.contourSettings.lineWeight)))

        // (j) Render by display mode
        let result: NSImage

        switch displayMode {
        case .original:
            fatalError("Handled above")

        case .colorFill:
            // Color fill; dim unselected regions if selection is active
            var displayColors = expandedColors
            var fillLineColor = clearColor
            var fillLineWeight: UInt32 = 0
            if let selection = selectedRegions, !selection.isEmpty {
                for i in 0..<displayColors.count {
                    if !selection.contains(i) {
                        let c = displayColors[i]
                        let gray: Float = 0.15
                        displayColors[i] = SIMD4<Float>(
                            c.x * 0.3 + gray * 0.7,
                            c.y * 0.3 + gray * 0.7,
                            c.z * 0.3 + gray * 0.7,
                            1.0
                        )
                    }
                }
                // Add contour lines for visual distinction when selection is active
                fillLineColor = blackColor
                fillLineWeight = UInt32(max(2, Int(config.contourSettings.lineWeight) + 1))
            }
            guard let tintTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: displayColors,
                lineColor: fillLineColor,
                lineWeight: fillLineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            guard let img = metal.imageFromTexture(tintTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = img
            stepStart = logElapsed("V2 color fill", since: stepStart)

        case .contourOnly:
            // White background with contour lines
            let whiteColors = [SIMD4<Float>](repeating: SIMD4<Float>(1, 1, 1, 1), count: numColors)
            guard let tintTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: whiteColors,
                lineColor: blackColor,
                lineWeight: lineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            guard let img = metal.imageFromTexture(tintTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = img
            stepStart = logElapsed("V2 contour only", since: stepStart)

        case .colorWithContour:
            // Full color with contour lines overlaid; dim unselected if selection active
            var contourColors = expandedColors
            var contourWeight = lineWeight
            if let selection = selectedRegions, !selection.isEmpty {
                for i in 0..<contourColors.count {
                    if !selection.contains(i) {
                        let c = contourColors[i]
                        let gray: Float = 0.15
                        contourColors[i] = SIMD4<Float>(
                            c.x * 0.3 + gray * 0.7,
                            c.y * 0.3 + gray * 0.7,
                            c.z * 0.3 + gray * 0.7,
                            1.0
                        )
                    }
                }
                contourWeight = UInt32(max(2, Int(config.contourSettings.lineWeight) + 1))
            }
            guard let tintTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: contourColors,
                lineColor: blackColor,
                lineWeight: contourWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            guard let img = metal.imageFromTexture(tintTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = img
            stepStart = logElapsed("V2 color+contour", since: stepStart)

        case .numbered:
            // White-tinted colors (20% palette + 80% white) with contours, then draw number labels
            let tintedColors: [SIMD4<Float>] = expandedColors.map { c in
                SIMD4<Float>(c.x * 0.2 + 0.8, c.y * 0.2 + 0.8, c.z * 0.2 + 0.8, 1.0)
            }
            guard let tintTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: tintedColors,
                lineColor: blackColor,
                lineWeight: lineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            guard let tintImage = metal.imageFromTexture(tintTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            stepStart = logElapsed("V2 numbered tint+boundary", since: stepStart)

            if config.contourSettings.showNumbers {
                let palette = PBNPalette(id: config.palette.id, name: config.palette.name, colors: config.palette.colors)
                result = drawNumberLabelsBatched(
                    tintImage,
                    facets: facets,
                    palette: palette,
                    settings: config.contourSettings,
                    numberAssignment: numberAssignment,
                    width: width,
                    height: height
                )
                stepStart = logElapsed("V2 batched number labels", since: stepStart)
            } else {
                result = tintImage
            }

        case .highlightRegion:
            // Color+contour base, then hover highlight
            guard let baseTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: expandedColors,
                lineColor: blackColor,
                lineWeight: lineWeight,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }

            guard let highlightTexture = metal.pbnHoverHighlight(
                regionMap: regionMap,
                baseImage: baseTexture,
                highlightedRegion: UInt32(highlightedRegion ?? 0),
                dimAlpha: 0.3
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }

            guard let img = metal.imageFromTexture(highlightTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = img
            stepStart = logElapsed("V2 highlight region", since: stepStart)

        case .sideBySide:
            // Original left, color fill right
            guard let colorTexture = metal.pbnTintAndBoundary(
                regionMap: regionMap,
                paletteColors: expandedColors,
                lineColor: clearColor,
                lineWeight: 0,
                width: width,
                height: height
            ) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            guard let colorImage = metal.imageFromTexture(colorTexture) else {
                throw PaintByNumbersRenderError.failedToRenderOutput
            }
            result = buildSideBySide(original: source, processed: colorImage)
            stepStart = logElapsed("V2 side-by-side", since: stepStart)
        }

        progress(1.0)
        pbnLog.info("[PBN-V2] Render complete (\(String(describing: displayMode))) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderStart))s total, \(facets.filter { !$0.isDeleted }.count) facets")

        // (k) Return the tuple
        return (result, regionMap, facets, numberAssignment)
    }

    // MARK: - Batched Number Labels (V2)

    /// Draw number labels for all non-deleted facets using a single CGBitmapContext pass.
    /// Uses facet label positions from the Chamfer distance transform rather than per-region centroid scanning.
    private func drawNumberLabelsBatched(
        _ baseImage: NSImage,
        facets: [PBNFacet],
        palette: PBNPalette,
        settings: PBNContourSettings,
        numberAssignment: PBNNumberAssignment? = nil,
        width: Int,
        height: Int
    ) -> NSImage {
        guard let baseCG = try? cgImage(from: baseImage) else { return baseImage }

        let space = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixelBuffer = [UInt8](repeating: 0, count: width * height * 4)

        guard let ctx = CGContext(
            data: &pixelBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return baseImage }

        // Draw the base image
        ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Font setup
        let baseFontSize = CGFloat(settings.numberFontSize)
        let fontSize = max(baseFontSize, CGFloat(max(width, height)) / 80.0)
        let ctFont = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let lineNS = settings.lineColor.nsColor

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: lineNS
        ]

        for facet in facets {
            guard !facet.isDeleted,
                  facet.pixelCount > 0,
                  facet.labelRadius > fontSize * 0.4 else { continue }

            let recipe = numberAssignment?.recipeByColorIndex[facet.colorIndex]
            let label = recipe?.canvasLabel ?? "\(facet.colorIndex + 1)"
            let attrString = CFAttributedStringCreate(
                nil,
                label as CFString,
                textAttributes as CFDictionary
            )!
            let line = CTLineCreateWithAttributedString(attrString)
            let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let labelWidth = lineBounds.width
            let labelHeight = lineBounds.height

            let pos = facet.labelPosition
            // CGContext has origin at bottom-left; facet positions are top-left origin
            let flippedY = CGFloat(height) - pos.y

            // Draw white rounded-rect pill background
            let pillRect = CGRect(
                x: pos.x - labelWidth / 2 - 4,
                y: flippedY - labelHeight / 2 - 2,
                width: labelWidth + 8,
                height: labelHeight + 4
            )
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            let pillPath = CGPath(
                roundedRect: pillRect,
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            )
            ctx.addPath(pillPath)
            ctx.fillPath()

            ctx.setStrokeColor(lineNS.cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(pillPath)
            ctx.strokePath()
            ctx.restoreGState()

            // Draw the number text centered in the pill
            ctx.saveGState()
            let textX = pos.x - labelWidth / 2
            let textY = flippedY - labelHeight / 2
            ctx.textPosition = CGPoint(x: textX, y: textY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        guard let cgImg = ctx.makeImage() else { return baseImage }
        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }

    // MARK: - Number Labels (CPU overlay on Metal-rendered image)

    /// Draw number labels onto a Metal-rendered tinted image using CoreText.
    /// Reads region centroids from the region map texture on CPU.
    private func drawNumberLabelsOnImage(
        _ baseImage: NSImage,
        regionMap: MTLTexture,
        palette: PBNPalette,
        settings: PBNContourSettings,
        numberAssignment: PBNNumberAssignment? = nil,
        width: Int,
        height: Int
    ) -> NSImage {
        // Read back the full region map to CPU for centroid computation
        let pixelCount = width * height
        var regionData = [UInt8](repeating: 0, count: pixelCount)
        regionMap.getBytes(
            &regionData,
            bytesPerRow: width,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        // Get the base image as CGImage for compositing
        guard let baseCG = try? cgImage(from: baseImage) else { return baseImage }

        let space = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixelBuffer = [UInt8](repeating: 0, count: pixelCount * 4)

        guard let ctx = CGContext(
            data: &pixelBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return baseImage }

        // Draw the base image
        ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Draw number labels
        let baseFontSize = CGFloat(settings.numberFontSize)
        let fontSize = max(baseFontSize, CGFloat(max(width, height)) / 80.0)
        let ctFont = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let lineNS = settings.lineColor.nsColor

        let regionCount = palette.colors.count

        for i in 0..<regionCount {
            let recipe = numberAssignment?.recipeByColorIndex[i]
            let label = recipe?.canvasLabel ?? "\(i + 1)"

            // Build a mask for this region from the region map data
            var mask = [UInt8](repeating: 0, count: pixelCount)
            var regionPixelCount = 0
            for j in 0..<pixelCount {
                if regionData[j] == UInt8(i) {
                    mask[j] = 255
                    regionPixelCount += 1
                }
            }
            guard regionPixelCount > 0 else { continue }

            let regionFraction = Double(regionPixelCount) / Double(pixelCount)

            let labelPositions: [CGPoint]
            if regionFraction > 0.08 {
                labelPositions = gridLabelPositions(mask: mask, width: width, height: height,
                                                    spacing: Int(fontSize * 6))
            } else {
                let centroid = computeCentroid(mask: mask, width: width, height: height)
                labelPositions = centroid.x >= 0 ? [centroid] : []
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: ctFont,
                .foregroundColor: lineNS
            ]
            let attrString = CFAttributedStringCreate(
                nil,
                label as CFString,
                attributes as CFDictionary
            )!
            let line = CTLineCreateWithAttributedString(attrString)
            let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let labelWidth = lineBounds.width
            let labelHeight = lineBounds.height

            for pos in labelPositions {
                let flippedY = CGFloat(height) - pos.y

                let pillRect = CGRect(
                    x: pos.x - labelWidth / 2 - 4,
                    y: flippedY - labelHeight / 2 - 2,
                    width: labelWidth + 8,
                    height: labelHeight + 4
                )
                ctx.saveGState()
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
                let pillPath = CGPath(
                    roundedRect: pillRect,
                    cornerWidth: 4,
                    cornerHeight: 4,
                    transform: nil
                )
                ctx.addPath(pillPath)
                ctx.fillPath()

                ctx.setStrokeColor(lineNS.cgColor)
                ctx.setLineWidth(0.75)
                ctx.addPath(pillPath)
                ctx.strokePath()
                ctx.restoreGState()

                ctx.saveGState()
                let textX = pos.x - labelWidth / 2
                let textY = flippedY - labelHeight / 2
                ctx.textPosition = CGPoint(x: textX, y: textY)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        guard let cgImg = ctx.makeImage() else { return baseImage }
        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }

    // MARK: - Timing Helpers

    private func logElapsed(_ label: String, since start: CFAbsoluteTime) -> CFAbsoluteTime {
        let now = CFAbsoluteTimeGetCurrent()
        pbnLog.info("[PBN] \(label) took \(String(format: "%.3f", now - start))s")
        return now
    }

    // MARK: - Main Render

    /// Main render entry point. Returns the composite image for the given display mode.
    func render(
        source: NSImage,
        config: PBNConfig,
        displayMode: PBNDisplayMode,
        highlightedRegion: Int? = nil,
        selectedRegions: Set<Int>? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        try Task.checkCancellation()

        let renderStart = CFAbsoluteTimeGetCurrent()

        let cgSource = try cgImage(from: source)
        let width = cgSource.width
        let height = cgSource.height

        let thresholds = config.thresholds
        let regionCount = thresholds.regionCount
        let expandedColors = config.palette.expandedColors(toCount: regionCount)
        let palette = PBNPalette(id: config.palette.id, name: config.palette.name, colors: expandedColors)

        pbnLog.info("[PBN] Render start: \(width)x\(height), regions=\(regionCount), palette=\(palette.colors.count) (expanded from \(config.palette.colors.count)), mode=\(String(describing: displayMode))")

        // Step 1: Grayscale conversion
        var stepStart = CFAbsoluteTimeGetCurrent()
        progress(0.05)
        var grayscaleBuffer = try grayscalePixelBuffer(from: cgSource)
        progress(0.10)
        stepStart = logElapsed("Grayscale conversion", since: stepStart)

        try Task.checkCancellation()
        await Task.yield()

        // Step 2: Optional posterization
        if config.posterizationLevels > 1 {
            posterize(buffer: &grayscaleBuffer, levels: config.posterizationLevels)
            stepStart = logElapsed("Posterization (levels=\(config.posterizationLevels))", since: stepStart)
        }
        progress(0.15)

        // Step 3: Optional pre-blur
        if config.blurRadius > 0 {
            gaussianBlur(buffer: &grayscaleBuffer, width: width, height: height, radius: config.blurRadius)
            stepStart = logElapsed("Gaussian blur (radius=\(config.blurRadius))", since: stepStart)
        }
        progress(0.20)

        try Task.checkCancellation()
        await Task.yield()

        // For colorFill (most common): single-pass, no masks needed
        if displayMode == .colorFill || displayMode == .original {
            if displayMode == .original {
                progress(1.0)
                pbnLog.info("[PBN] Render complete (original passthrough) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderStart))s")
                return source
            }
            let colorFillImage = buildColorFillFast(
                grayscale: grayscaleBuffer,
                thresholds: thresholds,
                palette: palette,
                width: width,
                height: height,
                selectedRegions: selectedRegions
            )
            stepStart = logElapsed("Color fill (fast LUT)", since: stepStart)
            progress(1.0)
            pbnLog.info("[PBN] Render complete (colorFill) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderStart))s")
            return colorFillImage
        }

        // For modes that need masks (contours, numbered, highlight, etc.)
        let masks = try buildRegionMasks(
            grayscale: grayscaleBuffer,
            thresholds: thresholds,
            width: width,
            height: height,
            progress: { value in
                progress(0.20 + value * 0.30)
            }
        )
        stepStart = logElapsed("Region mask building (\(masks.count) masks)", since: stepStart)

        // Log pixel counts per region mask
        for (i, mask) in masks.enumerated() {
            let pixelCount = mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            pbnLog.debug("[PBN] Region \(i): \(pixelCount) pixels")
        }

        progress(0.50)

        try Task.checkCancellation()
        await Task.yield()

        let result: NSImage
        switch displayMode {
        case .colorFill, .original:
            fatalError("Handled above")

        case .contourOnly:
            result = buildContourImage(masks: masks, settings: config.contourSettings, width: width, height: height)
            stepStart = logElapsed("Contour image", since: stepStart)

        case .numbered:
            result = buildNumberedImage(masks: masks, settings: config.contourSettings, palette: palette, width: width, height: height)
            stepStart = logElapsed("Numbered image", since: stepStart)

        case .colorWithContour:
            let colorFill = buildColorFillFast(grayscale: grayscaleBuffer, thresholds: thresholds, palette: palette, width: width, height: height, selectedRegions: selectedRegions)
            _ = logElapsed("Color fill (for composite)", since: stepStart)
            stepStart = CFAbsoluteTimeGetCurrent()
            let contour = buildContourImage(masks: masks, settings: config.contourSettings, width: width, height: height)
            _ = logElapsed("Contour (for composite)", since: stepStart)
            stepStart = CFAbsoluteTimeGetCurrent()
            result = compositeColorWithContour(colorFill: colorFill, contour: contour, width: width, height: height)
            stepStart = logElapsed("Composite blend", since: stepStart)

        case .highlightRegion:
            let regionIdx = highlightedRegion ?? 0
            guard regionIdx >= 0 && regionIdx < regionCount else {
                throw PaintByNumbersRenderError.invalidRegionIndex(regionIdx)
            }
            result = buildHighlightedRegionImage(masks: masks, highlightIndex: regionIdx, palette: palette, settings: config.contourSettings, width: width, height: height)
            stepStart = logElapsed("Highlighted region", since: stepStart)

        case .sideBySide:
            let colorFill = buildColorFillFast(grayscale: grayscaleBuffer, thresholds: thresholds, palette: palette, width: width, height: height, selectedRegions: selectedRegions)
            let contour = buildContourImage(masks: masks, settings: config.contourSettings, width: width, height: height)
            let composite = compositeColorWithContour(colorFill: colorFill, contour: contour, width: width, height: height)
            result = buildSideBySide(original: source, processed: composite)
            stepStart = logElapsed("Side-by-side composite", since: stepStart)
        }

        progress(1.0)
        pbnLog.info("[PBN] Render complete (\(String(describing: displayMode))) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - renderStart))s total")
        return result
    }

    // MARK: - Region Analysis

    /// Extract region analysis (coverage percentages, centroids).
    func analyzeRegions(
        source: NSImage,
        config: PBNConfig
    ) async -> [PBNRegion] {
        guard let cgSource = try? cgImage(from: source) else { return [] }
        let width = cgSource.width
        let height = cgSource.height

        guard var grayscaleBuffer = try? grayscalePixelBuffer(from: cgSource) else { return [] }

        if config.posterizationLevels > 1 {
            posterize(buffer: &grayscaleBuffer, levels: config.posterizationLevels)
        }
        if config.blurRadius > 0 {
            gaussianBlur(buffer: &grayscaleBuffer, width: width, height: height, radius: config.blurRadius)
        }

        let thresholds = config.thresholds
        let regionCount = thresholds.regionCount
        let expandedColors = config.palette.expandedColors(toCount: regionCount)
        let palette = PBNPalette(id: config.palette.id, name: config.palette.name, colors: expandedColors)
        let totalPixels = width * height

        guard let masks = try? buildRegionMasks(
            grayscale: grayscaleBuffer,
            thresholds: thresholds,
            width: width,
            height: height,
            progress: { _ in }
        ) else { return [] }

        var regions: [PBNRegion] = []

        for i in 0..<regionCount {
            guard i < masks.count else { break }
            let mask = masks[i]
            var count: Int = 0

            for y in 0..<height {
                for x in 0..<width {
                    if mask[y * width + x] > 0 {
                        count += 1
                    }
                }
            }

            let coverage = totalPixels > 0 ? Double(count) / Double(totalPixels) * 100.0 : 0
            let color = expandedColors[i]

            regions.append(PBNRegion(
                id: i,
                label: color.name,
                color: color,
                thresholdBounds: thresholds.bounds(for: i),
                isHighlighted: false,
                coveragePercent: coverage
            ))
        }

        return regions
    }

    // MARK: - Region Mask Export

    /// Export a single region as an isolated mask (white on black).
    func renderRegionMask(
        source: NSImage,
        config: PBNConfig,
        regionIndex: Int
    ) async -> NSImage {
        guard let cgSource = try? cgImage(from: source) else {
            return NSImage(size: source.size)
        }
        let width = cgSource.width
        let height = cgSource.height

        guard var grayscaleBuffer = try? grayscalePixelBuffer(from: cgSource) else {
            return NSImage(size: source.size)
        }

        if config.posterizationLevels > 1 {
            posterize(buffer: &grayscaleBuffer, levels: config.posterizationLevels)
        }
        if config.blurRadius > 0 {
            gaussianBlur(buffer: &grayscaleBuffer, width: width, height: height, radius: config.blurRadius)
        }

        guard let masks = try? buildRegionMasks(
            grayscale: grayscaleBuffer,
            thresholds: config.thresholds,
            width: width,
            height: height,
            progress: { _ in }
        ),
              regionIndex >= 0, regionIndex < masks.count else {
            return NSImage(size: source.size)
        }

        let mask = masks[regionIndex]
        return nsImage(fromGrayscale: mask, width: width, height: height)
    }

    // MARK: - Palette Swatch

    /// Render just the palette swatch strip (for export).
    /// Uses CGContext for thread safety (no lockFocus).
    func renderPaletteSwatch(
        palette: PBNPalette,
        size: CGSize
    ) -> NSImage {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return NSImage(size: size) }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        let count = palette.colors.count
        guard count > 0 else {
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let cgImg = ctx.makeImage() else { return NSImage(size: size) }
            return NSImage(cgImage: cgImg, size: size)
        }

        let swatchWidth = size.width / CGFloat(count)

        for (index, pbnColor) in palette.colors.enumerated() {
            let rect = CGRect(
                x: CGFloat(index) * swatchWidth,
                y: 0,
                width: swatchWidth,
                height: size.height
            )
            ctx.setFillColor(pbnColor.nsColor.cgColor)
            ctx.fill(rect)

            // Draw number label using CoreText for thread safety
            let label = "\(index + 1)"
            let fontSize = max(8, min(14, swatchWidth * 0.3))
            let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
            let textColor = contrastingTextColor(for: pbnColor.nsColor)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let attrString = NSAttributedString(string: label, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrString)
            let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

            ctx.saveGState()
            let textX = rect.midX - lineBounds.width / 2
            let textY = rect.midY - lineBounds.height / 2
            ctx.textPosition = CGPoint(x: textX, y: textY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()

            // Draw color name below number
            if !pbnColor.name.isEmpty {
                let nameFontSize = max(6, min(10, swatchWidth * 0.2))
                let nameFont = CTFontCreateWithName("Helvetica" as CFString, nameFontSize, nil)
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: nameFont,
                    .foregroundColor: textColor
                ]
                let nameAttrString = NSAttributedString(string: pbnColor.name, attributes: nameAttrs)
                let nameLine = CTLineCreateWithAttributedString(nameAttrString)
                let nameBounds = CTLineGetBoundsWithOptions(nameLine, .useOpticalBounds)

                ctx.saveGState()
                let nameX = rect.midX - nameBounds.width / 2
                let nameY = rect.midY - lineBounds.height / 2 - nameBounds.height - 2
                ctx.textPosition = CGPoint(x: nameX, y: nameY)
                CTLineDraw(nameLine, ctx)
                ctx.restoreGState()
            }
        }

        guard let cgImg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImg, size: size)
    }

    // MARK: - Image Conversion Helpers

    func cgImage(from nsImage: NSImage) throws -> CGImage {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cg = bitmap.cgImage else {
            throw PaintByNumbersRenderError.failedToCreateCGImage
        }
        return cg
    }

    /// Convert a CGImage to a grayscale UInt8 pixel buffer using Accelerate.
    func grayscalePixelBuffer(from cgImage: CGImage) throws -> [UInt8] {
        let width = cgImage.width
        let height = cgImage.height
        let pixelCount = width * height

        // Create an ARGB pixel buffer
        var argbBuffer = [UInt8](repeating: 0, count: pixelCount * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: &argbBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw PaintByNumbersRenderError.failedToCreatePixelBuffer
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert BGRA to grayscale using luminance weights via Accelerate
        // byteOrder32Little + premultipliedFirst = BGRA layout
        var grayscale = [UInt8](repeating: 0, count: pixelCount)

        // Extract channels
        var blueChannel = [Float](repeating: 0, count: pixelCount)
        var greenChannel = [Float](repeating: 0, count: pixelCount)
        var redChannel = [Float](repeating: 0, count: pixelCount)
        var grayFloat = [Float](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let offset = i * 4
            blueChannel[i] = Float(argbBuffer[offset])
            greenChannel[i] = Float(argbBuffer[offset + 1])
            redChannel[i] = Float(argbBuffer[offset + 2])
        }

        // Luminance: 0.299 * R + 0.587 * G + 0.114 * B
        var rWeight: Float = 0.299
        var gWeight: Float = 0.587
        var bWeight: Float = 0.114

        // R * 0.299
        vDSP_vsmul(redChannel, 1, &rWeight, &grayFloat, 1, vDSP_Length(pixelCount))
        // + G * 0.587
        var temp = [Float](repeating: 0, count: pixelCount)
        vDSP_vsmul(greenChannel, 1, &gWeight, &temp, 1, vDSP_Length(pixelCount))
        vDSP_vadd(grayFloat, 1, temp, 1, &grayFloat, 1, vDSP_Length(pixelCount))
        // + B * 0.114
        vDSP_vsmul(blueChannel, 1, &bWeight, &temp, 1, vDSP_Length(pixelCount))
        vDSP_vadd(grayFloat, 1, temp, 1, &grayFloat, 1, vDSP_Length(pixelCount))

        // Convert Float -> UInt8
        var minVal: Float = 0
        var maxVal: Float = 255
        vDSP_vclip(grayFloat, 1, &minVal, &maxVal, &grayFloat, 1, vDSP_Length(pixelCount))
        vDSP_vfixu8(grayFloat, 1, &grayscale, 1, vDSP_Length(pixelCount))

        return grayscale
    }

    // MARK: - Posterization

    /// Reduce grayscale buffer to N distinct tonal levels.
    /// Formula: floor(pixel / step) * step, where step = 255 / (levels - 1)
    func posterize(buffer: inout [UInt8], levels: Int) {
        guard levels > 1 else { return }
        let count = buffer.count
        let step = 255.0 / Float(levels - 1)

        var floatBuffer = [Float](repeating: 0, count: count)
        vDSP_vfltu8(buffer, 1, &floatBuffer, 1, vDSP_Length(count))

        // Divide by step
        var stepVal = step
        vDSP_vsdiv(floatBuffer, 1, &stepVal, &floatBuffer, 1, vDSP_Length(count))

        // Floor
        var floored = [Float](repeating: 0, count: count)
        vvfloorf(&floored, floatBuffer, [Int32(count)])

        // Multiply by step
        vDSP_vsmul(floored, 1, &stepVal, &floatBuffer, 1, vDSP_Length(count))

        // Clip and convert back
        var minVal: Float = 0
        var maxVal: Float = 255
        vDSP_vclip(floatBuffer, 1, &minVal, &maxVal, &floatBuffer, 1, vDSP_Length(count))
        vDSP_vfixu8(floatBuffer, 1, &buffer, 1, vDSP_Length(count))
    }

    // MARK: - Gaussian Blur (vImage)

    /// Apply Gaussian blur to grayscale buffer using vImage tent convolution.
    func gaussianBlur(buffer: inout [UInt8], width: Int, height: Int, radius: Double) {
        guard width > 0, height > 0 else { return }

        // Kernel size must be odd
        var kernelSize = Int(ceil(radius * 3)) | 1
        if kernelSize < 3 { kernelSize = 3 }

        let pixelCount = width * height
        var dstData = [UInt8](repeating: 0, count: pixelCount)

        buffer.withUnsafeMutableBufferPointer { srcPtr in
            dstData.withUnsafeMutableBufferPointer { dstPtr in
                var srcBuf = vImage_Buffer(
                    data: srcPtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var dstBuf = vImage_Buffer(
                    data: dstPtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                _ = vImageTentConvolve_Planar8(
                    &srcBuf,
                    &dstBuf,
                    nil,
                    0, 0,
                    UInt32(kernelSize),
                    UInt32(kernelSize),
                    0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }

        buffer = dstData
    }

    // MARK: - Region Mask Building

    /// Build binary masks for each threshold region.
    /// Each mask is a [UInt8] where 255 = in region, 0 = out.
    /// Direct port of the notebook's cv2.inRange(image, lower, upper) approach.
    func buildRegionMasks(
        grayscale: [UInt8],
        thresholds: PBNThresholdSet,
        width: Int,
        height: Int,
        progress: @escaping (Double) -> Void
    ) throws -> [[UInt8]] {
        let pixelCount = width * height
        let regionCount = thresholds.regionCount
        var masks: [[UInt8]] = []

        pbnLog.debug("[PBN] Building \(regionCount) region masks for \(pixelCount) pixels")

        for i in 0..<regionCount {
            try Task.checkCancellation()

            let (lower, upper) = thresholds.bounds(for: i)
            let lowerU8 = UInt8(clamping: lower)
            let upperU8 = UInt8(clamping: upper)

            // cv2.inRange equivalent: mask = (pixel >= lower) & (pixel <= upper)
            var mask = [UInt8](repeating: 0, count: pixelCount)
            for j in 0..<pixelCount {
                let val = grayscale[j]
                if val >= lowerU8 && val <= upperU8 {
                    mask[j] = 255
                }
            }

            masks.append(mask)
            progress(Double(i + 1) / Double(regionCount))
        }

        return masks
    }

    // MARK: - Region Index Map (for hover detection)

    /// Build a flat [UInt8] array where each pixel stores its region index (0-based).
    /// Pixels not belonging to any region get 255.
    /// Returns the map, width, and height as a tuple.
    func buildRegionIndexMap(
        source: NSImage,
        config: PBNConfig
    ) -> (map: [UInt8], width: Int, height: Int) {
        guard let cgSource = try? cgImage(from: source) else {
            return ([], 0, 0)
        }
        let width = cgSource.width
        let height = cgSource.height
        let pixelCount = width * height

        guard var grayscaleBuffer = try? grayscalePixelBuffer(from: cgSource) else {
            return ([], 0, 0)
        }

        if config.posterizationLevels > 1 {
            posterize(buffer: &grayscaleBuffer, levels: config.posterizationLevels)
        }
        if config.blurRadius > 0 {
            gaussianBlur(buffer: &grayscaleBuffer, width: width, height: height, radius: config.blurRadius)
        }

        let thresholds = config.thresholds
        let regionCount = thresholds.regionCount

        // Build a LUT: grayscale value -> region index
        var regionLUT = [UInt8](repeating: 255, count: 256)
        for r in 0..<regionCount {
            let (lower, upper) = thresholds.bounds(for: r)
            for v in lower...min(upper, 255) {
                regionLUT[v] = UInt8(clamping: r)
            }
        }

        // Single pass over pixels using the LUT
        var indexMap = [UInt8](repeating: 255, count: pixelCount)
        for j in 0..<pixelCount {
            indexMap[j] = regionLUT[Int(grayscaleBuffer[j])]
        }

        return (indexMap, width, height)
    }

    // MARK: - Fast Color Fill (single pass, no masks)

    /// Single-pass color fill: for each pixel, find its region by threshold and assign color.
    /// This is the notebook's exact approach but in ONE loop -- no intermediate mask arrays.
    /// ~10x faster than buildRegionMasks + buildColorFill.
    private func buildColorFillFast(
        grayscale: [UInt8],
        thresholds: PBNThresholdSet,
        palette: PBNPalette,
        width: Int,
        height: Int,
        selectedRegions: Set<Int>? = nil
    ) -> NSImage {
        let pixelCount = width * height
        let regionCount = thresholds.regionCount
        // Expand palette to cover all regions
        let expandedColors = PBNPalette.expandedColors(from: palette, count: regionCount)

        let hasSelection = selectedRegions != nil && !selectedRegions!.isEmpty

        // Helper: dim a color channel (blend toward gray at 30% original + 70% gray)
        func dimmed(_ value: UInt8) -> UInt8 {
            let gray: UInt8 = 160  // neutral mid-gray target
            return UInt8(clamping: Int(Double(value) * 0.3 + Double(gray) * 0.7))
        }

        // Pre-compute lookup table: for each grayscale value 0-255, which region?
        // Then map region -> RGBA color. This is O(256) setup + O(pixels) fill.
        var colorLUT = [(r: UInt8, g: UInt8, b: UInt8)](repeating: (0, 0, 0), count: 256)

        // Background color (last palette color)
        let bgColor = expandedColors.last ?? PBNColor(red: 1, green: 1, blue: 1, name: "White")
        let bgR = UInt8(clamping: Int(bgColor.red * 255))
        let bgG = UInt8(clamping: Int(bgColor.green * 255))
        let bgB = UInt8(clamping: Int(bgColor.blue * 255))

        // Determine if the background region (last region) is selected
        let bgDimmed = hasSelection && !selectedRegions!.contains(regionCount - 1)

        // Fill LUT with background
        for i in 0..<256 {
            if bgDimmed {
                colorLUT[i] = (dimmed(bgR), dimmed(bgG), dimmed(bgB))
            } else {
                colorLUT[i] = (bgR, bgG, bgB)
            }
        }

        // Assign colors per region
        for r in 0..<regionCount {
            let (lower, upper) = thresholds.bounds(for: r)
            let c = expandedColors[r]
            let cr = UInt8(clamping: Int(c.red * 255))
            let cg = UInt8(clamping: Int(c.green * 255))
            let cb = UInt8(clamping: Int(c.blue * 255))

            let isDimmed = hasSelection && !selectedRegions!.contains(r)

            for v in lower...min(upper, 255) {
                if isDimmed {
                    colorLUT[v] = (dimmed(cr), dimmed(cg), dimmed(cb))
                } else {
                    colorLUT[v] = (cr, cg, cb)
                }
            }
        }

        // Single pass: look up each pixel's color from LUT
        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        for j in 0..<pixelCount {
            let color = colorLUT[Int(grayscale[j])]
            let offset = j * 4
            rgba[offset] = color.r
            rgba[offset + 1] = color.g
            rgba[offset + 2] = color.b
            // alpha already 255
        }

        return nsImage(fromRGBA: rgba, width: width, height: height)
    }

    // MARK: - Color Fill (mask-based, for modes that need masks)

    /// Composite colored regions onto a background -- matching the notebook's approach:
    /// canvas = np.full((h, w, 3), background_color)
    /// canvas[mask > 0] = region_color
    func buildColorFill(
        masks: [[UInt8]],
        palette: PBNPalette,
        width: Int,
        height: Int
    ) -> NSImage {
        let pixelCount = width * height
        let regionCount = masks.count
        // Expand palette to cover all masks
        let expandedColors = PBNPalette.expandedColors(from: palette, count: regionCount)

        // Start with the last palette color as background (paper/highlight color),
        // matching the notebook's toned-paper background approach
        let bgColor = expandedColors.last ?? PBNColor(red: 1, green: 1, blue: 1, name: "White")
        let bgR = UInt8(clamping: Int(bgColor.red * 255))
        let bgG = UInt8(clamping: Int(bgColor.green * 255))
        let bgB = UInt8(clamping: Int(bgColor.blue * 255))

        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        // Fill background
        for j in 0..<pixelCount {
            let offset = j * 4
            rgba[offset] = bgR
            rgba[offset + 1] = bgG
            rgba[offset + 2] = bgB
            rgba[offset + 3] = 255
        }

        // Overlay each region's color where mask > 0
        for (i, mask) in masks.enumerated() {
            let color = expandedColors[i]
            let r = UInt8(clamping: Int(color.red * 255))
            let g = UInt8(clamping: Int(color.green * 255))
            let b = UInt8(clamping: Int(color.blue * 255))

            for j in 0..<pixelCount {
                if mask[j] > 0 {
                    let offset = j * 4
                    rgba[offset] = r
                    rgba[offset + 1] = g
                    rgba[offset + 2] = b
                }
            }
        }

        return nsImage(fromRGBA: rgba, width: width, height: height)
    }

    // MARK: - Contour Extraction

    /// Build contour image: black lines on white background at region boundaries.
    /// Uses CGContext directly for thread safety (no lockFocus).
    private func buildContourImage(
        masks: [[UInt8]],
        settings: PBNContourSettings,
        width: Int,
        height: Int
    ) -> NSImage {
        pbnLog.debug("[PBN] Building contour image \(width)x\(height) with \(masks.count) masks")

        // Use a pixel buffer approach for boundary drawing -- much faster than per-pixel CGContext.fill()
        let pixelCount = width * height
        let lineWeight = max(1, Int(settings.lineWeight))

        // Parse line color
        let lineNS = settings.lineColor.nsColor
        let lineR = UInt8(clamping: Int((lineNS.redComponent) * 255))
        let lineG = UInt8(clamping: Int((lineNS.greenComponent) * 255))
        let lineB = UInt8(clamping: Int((lineNS.blueComponent) * 255))

        // Start with white RGBA buffer
        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)

        for mask in masks {
            let boundary = extractBoundary(mask: mask, width: width, height: height)

            // Draw boundary pixels with line weight expansion
            let halfWeight = lineWeight / 2
            for y in 0..<height {
                for x in 0..<width {
                    if boundary[y * width + x] > 0 {
                        // Expand by line weight
                        let minY = max(0, y - halfWeight)
                        let maxY = min(height - 1, y + halfWeight)
                        let minX = max(0, x - halfWeight)
                        let maxX = min(width - 1, x + halfWeight)

                        for py in minY...maxY {
                            for px in minX...maxX {
                                let offset = (py * width + px) * 4
                                rgba[offset] = lineR
                                rgba[offset + 1] = lineG
                                rgba[offset + 2] = lineB
                                // alpha stays 255
                            }
                        }
                    }
                }
            }
        }

        return nsImage(fromRGBA: rgba, width: width, height: height)
    }

    /// Extract boundary pixels from a mask using dilation - erosion (morphological gradient).
    private func extractBoundary(mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        let pixelCount = width * height

        // Use Accelerate vImage for morphological dilate/erode (3x3 kernel)
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: mask),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        var dilated = [UInt8](repeating: 0, count: pixelCount)
        var eroded = [UInt8](repeating: 0, count: pixelCount)
        var dilBuf = vImage_Buffer(data: &dilated, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width)
        var eroBuf = vImage_Buffer(data: &eroded, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width)

        // 3x3 kernel for dilate (max) and erode (min)
        let k3x3: [UInt8] = [0,0,0,0,0,0,0,0,0]
        vImageDilate_Planar8(&srcBuffer, &dilBuf, 0, 0, k3x3, 3, 3, vImage_Flags(kvImageEdgeExtend))
        vImageErode_Planar8(&srcBuffer, &eroBuf, 0, 0, k3x3, 3, 3, vImage_Flags(kvImageEdgeExtend))

        // Boundary = dilated XOR eroded (where they differ)
        var boundary = [UInt8](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            boundary[i] = dilated[i] != eroded[i] ? 255 : 0
        }

        return boundary
    }

    // MARK: - Numbered Image

    /// Build image with contours and region number labels at centroids.
    /// Uses pixel buffer for fills and CGContext for text -- all thread-safe (no lockFocus).
    private func buildNumberedImage(
        masks: [[UInt8]],
        settings: PBNContourSettings,
        palette: PBNPalette,
        width: Int,
        height: Int
    ) -> NSImage {
        pbnLog.debug("[PBN] Building numbered image \(width)x\(height)")
        let pixelCount = width * height
        let paletteColors = palette.colors

        // ---- Phase 1: Build pixel buffer with region tints ----
        // Start with white, then assign each pixel to its region color at 20% opacity.
        // Single-pass: build a region index map, then tint once per pixel.
        var regionMap = [Int](repeating: -1, count: pixelCount)
        for (i, mask) in masks.enumerated() {
            for idx in 0..<pixelCount where mask[idx] > 0 {
                regionMap[idx] = i
            }
        }

        // Pre-compute tint colors (integer math, no per-pixel float)
        let alpha = 51 // 20% of 255
        let invAlpha = 255 - alpha
        var tintPixels = [UInt32]()
        tintPixels.reserveCapacity(paletteColors.count)
        for c in paletteColors {
            let ns = c.nsColor
            let r = UInt32(ns.redComponent * 255)
            let g = UInt32(ns.greenComponent * 255)
            let b = UInt32(ns.blueComponent * 255)
            // Pre-blend: tint over white (255) at 20% alpha
            let blendR = (r * UInt32(alpha) + 255 * UInt32(invAlpha)) / 255
            let blendG = (g * UInt32(alpha) + 255 * UInt32(invAlpha)) / 255
            let blendB = (b * UInt32(alpha) + 255 * UInt32(invAlpha)) / 255
            tintPixels.append(UInt32(blendR) | (UInt32(blendG) << 8) | (UInt32(blendB) << 16) | (0xFF << 24))
        }

        var pixelBuffer = [UInt32](repeating: 0xFFFFFFFF, count: pixelCount)
        for idx in 0..<pixelCount {
            let region = regionMap[idx]
            if region >= 0 {
                let colorIdx = region < tintPixels.count ? region : region % max(1, tintPixels.count)
                pixelBuffer[idx] = tintPixels[colorIdx]
            }
        }

        // ---- Phase 2: Build combined boundary mask, then stamp line pixels ----
        // Merge all region boundaries into one mask (avoids per-mask full-image iteration)
        var combinedBoundary = [UInt8](repeating: 0, count: pixelCount)
        for mask in masks {
            let boundary = extractBoundary(mask: mask, width: width, height: height)
            for i in 0..<pixelCount where boundary[i] > 0 {
                combinedBoundary[i] = 255
            }
        }

        let lineNS = settings.lineColor.nsColor
        let lineR = UInt8(clamping: Int(lineNS.redComponent * 255))
        let lineG = UInt8(clamping: Int(lineNS.greenComponent * 255))
        let lineB = UInt8(clamping: Int(lineNS.blueComponent * 255))
        let linePixel = UInt32(lineR) | (UInt32(lineG) << 8) | (UInt32(lineB) << 16) | (0xFF << 24)
        let lineWeight = max(1, Int(settings.lineWeight))

        if lineWeight <= 1 {
            // Fast path: no dilation needed, direct stamp
            for idx in 0..<pixelCount where combinedBoundary[idx] > 0 {
                pixelBuffer[idx] = linePixel
            }
        } else {
            // Dilate the boundary mask by half-weight using vImage, then stamp
            let halfWeight = lineWeight / 2
            let kernelSize = halfWeight * 2 + 1
            var srcBuf = vImage_Buffer(data: &combinedBoundary, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: width)
            var dilatedBoundary = [UInt8](repeating: 0, count: pixelCount)
            var dstBuf = vImage_Buffer(data: &dilatedBoundary, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: width)
            let kernel = [UInt8](repeating: 0, count: kernelSize * kernelSize)
            vImageDilate_Planar8(&srcBuf, &dstBuf, 0, 0, kernel, vImagePixelCount(kernelSize), vImagePixelCount(kernelSize), vImage_Flags(kvImageEdgeExtend))
            for idx in 0..<pixelCount where dilatedBoundary[idx] > 0 {
                pixelBuffer[idx] = linePixel
            }
        }

        // ---- Phase 3: Create CGContext from pixel buffer and draw number labels ----
        let space = CGColorSpaceCreateDeviceRGB()
        // Copy pixel buffer into RGBA byte array for CGContext
        var rgbaBytes = [UInt8](repeating: 0, count: pixelCount * 4)
        pixelBuffer.withUnsafeBufferPointer { src in
            rgbaBytes.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, src.baseAddress!, pixelCount * 4)
            }
        }

        guard let ctx = CGContext(
            data: &rgbaBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            pbnLog.error("[PBN] Failed to create CGContext for numbered image")
            return nsImage(fromRGBA: rgbaBytes, width: width, height: height)
        }

        // Draw number labels using CoreText (thread-safe, no NSGraphicsContext needed)
        if settings.showNumbers {
            let baseFontSize = CGFloat(settings.numberFontSize)
            let fontSize = max(baseFontSize, CGFloat(max(width, height)) / 80.0)
            let ctFont = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)

            for (i, mask) in masks.enumerated() {
                let label = "\(i + 1)"

                // Count region pixels to decide how many labels to place
                let regionPixels = mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
                guard regionPixels > 0 else { continue }

                let regionArea = Double(regionPixels)
                let totalArea = Double(width * height)
                let regionFraction = regionArea / totalArea

                // Place multiple labels in large regions (grid sampling)
                let labelPositions: [CGPoint]
                if regionFraction > 0.08 {
                    labelPositions = gridLabelPositions(mask: mask, width: width, height: height,
                                                        spacing: Int(fontSize * 6))
                } else if regionFraction > 0.02 {
                    let centroid = computeCentroid(mask: mask, width: width, height: height)
                    labelPositions = centroid.x >= 0 ? [centroid] : []
                } else {
                    let centroid = computeCentroid(mask: mask, width: width, height: height)
                    labelPositions = centroid.x >= 0 ? [centroid] : []
                }

                // Create attributed string for measurement
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: ctFont,
                    .foregroundColor: lineNS
                ]
                let attrString = CFAttributedStringCreate(
                    nil,
                    label as CFString,
                    attributes as CFDictionary
                )!
                let line = CTLineCreateWithAttributedString(attrString)
                let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let labelWidth = lineBounds.width
                let labelHeight = lineBounds.height

                for pos in labelPositions {
                    // CGContext has origin at bottom-left, our mask Y is top-down
                    let flippedY = CGFloat(height) - pos.y

                    // White pill background
                    let pillRect = CGRect(
                        x: pos.x - labelWidth / 2 - 4,
                        y: flippedY - labelHeight / 2 - 2,
                        width: labelWidth + 8,
                        height: labelHeight + 4
                    )
                    ctx.saveGState()
                    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
                    let pillPath = CGPath(
                        roundedRect: pillRect,
                        cornerWidth: 4,
                        cornerHeight: 4,
                        transform: nil
                    )
                    ctx.addPath(pillPath)
                    ctx.fillPath()

                    // Border
                    ctx.setStrokeColor(lineNS.cgColor)
                    ctx.setLineWidth(0.75)
                    ctx.addPath(pillPath)
                    ctx.strokePath()
                    ctx.restoreGState()

                    // Draw text using CoreText
                    ctx.saveGState()
                    let textX = pos.x - labelWidth / 2
                    let textY = flippedY - labelHeight / 2
                    ctx.textPosition = CGPoint(x: textX, y: textY)
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
        }

        guard let cgImg = ctx.makeImage() else {
            pbnLog.error("[PBN] Failed to create CGImage from numbered image context")
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }

    /// Compute the centroid (average x, y) of nonzero pixels in a mask.
    private func computeCentroid(mask: [UInt8], width: Int, height: Int) -> CGPoint {
        var sumX: Double = 0
        var sumY: Double = 0
        var count: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                if mask[y * width + x] > 0 {
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }

        guard count > 0 else { return CGPoint(x: -1, y: -1) }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    /// Place labels on a grid within a region mask, returning only positions that land inside the region.
    private func gridLabelPositions(mask: [UInt8], width: Int, height: Int, spacing: Int) -> [CGPoint] {
        let step = max(spacing, 30)
        var positions: [CGPoint] = []
        var y = step / 2
        while y < height {
            var x = step / 2
            while x < width {
                if mask[y * width + x] > 0 {
                    // Verify the point isn't too close to the boundary
                    let margin = 4
                    let inBounds = x >= margin && x < width - margin && y >= margin && y < height - margin
                    if inBounds {
                        positions.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    }
                }
                x += step
            }
            y += step
        }
        // Always include the centroid if no grid points landed inside
        if positions.isEmpty {
            let centroid = computeCentroid(mask: mask, width: width, height: height)
            if centroid.x >= 0 { positions.append(centroid) }
        }
        return positions
    }

    // MARK: - Composite Modes

    /// Composite color fill with contour overlay using Core Image.
    private func compositeColorWithContour(
        colorFill: NSImage,
        contour: NSImage,
        width: Int,
        height: Int
    ) -> NSImage {
        guard let colorCG = try? cgImage(from: colorFill),
              let contourCG = try? cgImage(from: contour) else {
            return colorFill
        }

        let colorCI = CIImage(cgImage: colorCG)
        let contourCI = CIImage(cgImage: contourCG)

        // Multiply blend: contour lines (black on white) darken the color fill
        let composited = contourCI.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: colorCI
        ])

        let extent = composited.extent
        guard let outputCG = context.createCGImage(composited, from: extent) else {
            return colorFill
        }

        return NSImage(cgImage: outputCG, size: NSSize(width: width, height: height))
    }

    /// Build highlighted region image: full color fill with one region bright, others dimmed.
    private func buildHighlightedRegionImage(
        masks: [[UInt8]],
        highlightIndex: Int,
        palette: PBNPalette,
        settings: PBNContourSettings,
        width: Int,
        height: Int
    ) -> NSImage {
        let pixelCount = width * height
        let expandedColors = PBNPalette.expandedColors(from: palette, count: masks.count)
        var rgba = [UInt8](repeating: 240, count: pixelCount * 4) // light gray background

        // Set alpha channel
        for j in 0..<pixelCount {
            rgba[j * 4 + 3] = 255
        }

        for (i, mask) in masks.enumerated() {
            let color = expandedColors[i]
            let isHighlighted = (i == highlightIndex)

            let r: UInt8
            let g: UInt8
            let b: UInt8

            if isHighlighted {
                r = UInt8(clamping: Int(color.red * 255))
                g = UInt8(clamping: Int(color.green * 255))
                b = UInt8(clamping: Int(color.blue * 255))
            } else {
                // Dimmed: blend toward light gray
                let dim = 0.3
                let inv = 1.0 - dim
                let dr = color.red * 255.0 * dim + 200.0 * inv
                let dg = color.green * 255.0 * dim + 200.0 * inv
                let db = color.blue * 255.0 * dim + 200.0 * inv
                r = UInt8(clamping: Int(dr))
                g = UInt8(clamping: Int(dg))
                b = UInt8(clamping: Int(db))
            }

            for j in 0..<pixelCount {
                if mask[j] > 0 {
                    let offset = j * 4
                    rgba[offset] = r
                    rgba[offset + 1] = g
                    rgba[offset + 2] = b
                }
            }
        }

        let baseImage = nsImage(fromRGBA: rgba, width: width, height: height)

        // Overlay contours
        let contourImage = buildContourImage(
            masks: masks,
            settings: settings,
            width: width,
            height: height
        )

        return compositeColorWithContour(
            colorFill: baseImage,
            contour: contourImage,
            width: width,
            height: height
        )
    }

    /// Build side-by-side comparison: original on left, processed on right.
    /// Uses CGContext for thread safety (no lockFocus).
    private func buildSideBySide(original: NSImage, processed: NSImage) -> NSImage {
        let oSize = original.size
        let pSize = processed.size
        let maxHeight = max(oSize.height, pSize.height)
        let totalWidth = oSize.width + pSize.width + 2 // 2px divider

        let w = Int(totalWidth)
        let h = Int(maxHeight)
        guard w > 0, h > 0 else { return NSImage(size: NSSize(width: totalWidth, height: maxHeight)) }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: totalWidth, height: maxHeight))
        }

        // Clear to white
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Draw original on left
        if let oCG = try? cgImage(from: original) {
            let oRect = CGRect(
                x: 0,
                y: (maxHeight - oSize.height) / 2,
                width: oSize.width,
                height: oSize.height
            )
            ctx.draw(oCG, in: oRect)
        }

        // Draw divider
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1.0))
        ctx.fill(CGRect(x: oSize.width, y: 0, width: 2, height: maxHeight))

        // Draw processed on right
        if let pCG = try? cgImage(from: processed) {
            let pRect = CGRect(
                x: oSize.width + 2,
                y: (maxHeight - pSize.height) / 2,
                width: pSize.width,
                height: pSize.height
            )
            ctx.draw(pCG, in: pRect)
        }

        guard let cgImg = ctx.makeImage() else {
            return NSImage(size: NSSize(width: totalWidth, height: maxHeight))
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: totalWidth, height: maxHeight))
    }

    // MARK: - NSImage Construction

    /// Create an NSImage from a grayscale UInt8 buffer.
    private func nsImage(fromGrayscale buffer: [UInt8], width: Int, height: Int) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        var mutableBuffer = buffer
        guard let provider = CGDataProvider(data: Data(bytes: &mutableBuffer, count: buffer.count) as CFData),
              let cgImg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }

    /// Create an NSImage from an RGBA UInt8 buffer.
    private func nsImage(fromRGBA buffer: [UInt8], width: Int, height: Int) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let cgImg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }

    // MARK: - Color Utilities

    /// Return black or white depending on which contrasts better against the given color.
    private func contrastingTextColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .black }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.5 ? .black : .white
    }
}
