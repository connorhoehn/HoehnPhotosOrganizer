import AppKit

/// Type-safe Swift wrapper around OpenCV operations via Obj-C++ bridge.
/// All operations run synchronously on the calling thread — wrap in Task for async.
final class CVImageProcessor {

    // MARK: - Pencil Sketch Pipeline

    struct PencilSketchParams {
        var blurRadius: Double = 30
        var brightness: Double = -20
        var contrast: Double = 130
        var noiseStrength: Double = 8
        var sharpAmount: Double = 1.5
    }

    static func pencilSketch(_ source: NSImage, params: PencilSketchParams = .init()) -> NSImage? {
        OpenCVBridge.pencilSketch(
            source,
            blurRadius: params.blurRadius,
            brightness: params.brightness,
            contrast: params.contrast,
            noiseStrength: params.noiseStrength,
            sharpAmount: params.sharpAmount
        )
    }

    // MARK: - Threshold / Chiaroscuro

    struct ThresholdZone {
        let lower: Int  // 0-255
        let upper: Int  // 0-255
        let color: (r: UInt8, g: UInt8, b: UInt8)
    }

    static func thresholdMap(
        _ grayscale: NSImage,
        zones: [ThresholdZone],
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8)
    ) -> NSImage? {
        // Build the parallel arrays that the bridge expects:
        // thresholds: N boundary values (ascending, 0-255)
        // colors: N+1 RGB triplets, one per zone
        // The bridge divides the grayscale range into zones separated by the thresholds.
        // zones map: zone[i] occupies [thresholds[i-1], thresholds[i]).
        // We derive thresholds from the zone boundaries.
        let thresholds = zones.dropFirst().map { NSNumber(value: $0.lower) }
        let colors: [[NSNumber]] = zones.map { zone in
            [NSNumber(value: zone.color.r), NSNumber(value: zone.color.g), NSNumber(value: zone.color.b)]
        }
        let bgRGB: [NSNumber] = [
            NSNumber(value: backgroundColor.r),
            NSNumber(value: backgroundColor.g),
            NSNumber(value: backgroundColor.b)
        ]
        return OpenCVBridge.thresholdMap(
            grayscale,
            thresholds: thresholds,
            colors: colors,
            backgroundColor: bgRGB
        )
    }

    /// Convenience overload using PBNThresholdSet + PBNPalette directly.
    static func thresholdMap(
        _ grayscale: NSImage,
        thresholds: PBNThresholdSet,
        palette: PBNPalette
    ) -> NSImage? {
        let thresholdNumbers = thresholds.thresholds.map { NSNumber(value: $0) }
        let colors: [[NSNumber]] = palette.colors.map { c in
            [
                NSNumber(value: UInt8(round(c.red * 255))),
                NSNumber(value: UInt8(round(c.green * 255))),
                NSNumber(value: UInt8(round(c.blue * 255)))
            ]
        }
        // Background is the last palette color (paper)
        let bg = palette.colors.last ?? palette.colors[0]
        let bgRGB: [NSNumber] = [
            NSNumber(value: UInt8(round(bg.red * 255))),
            NSNumber(value: UInt8(round(bg.green * 255))),
            NSNumber(value: UInt8(round(bg.blue * 255)))
        ]
        return OpenCVBridge.thresholdMap(
            grayscale,
            thresholds: thresholdNumbers,
            colors: colors,
            backgroundColor: bgRGB
        )
    }

    // MARK: - In-Range Mask

    static func inRangeMask(_ grayscale: NSImage, lower: Int, upper: Int) -> NSImage? {
        OpenCVBridge.inRangeMask(grayscale, lower: Int32(lower), upper: Int32(upper))
    }

    // MARK: - K-Means Quantization

    struct QuantizationResult {
        let image: NSImage
        let palette: [(r: UInt8, g: UInt8, b: UInt8)]
        let labelData: Data  // int32 per pixel
    }

    static func kmeansQuantize(_ source: NSImage, numColors: Int, attempts: Int = 10) -> QuantizationResult? {
        guard let dict = OpenCVBridge.kmeansQuantize(source, numColors: Int32(numColors), attempts: Int32(attempts)) else {
            return nil
        }
        guard let image = dict["image"] as? NSImage,
              let paletteArray = dict["palette"] as? [[NSNumber]],
              let labelData = dict["labels"] as? Data else {
            return nil
        }
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = paletteArray.map { triplet in
            (r: triplet[0].uint8Value, g: triplet[1].uint8Value, b: triplet[2].uint8Value)
        }
        return QuantizationResult(image: image, palette: palette, labelData: labelData)
    }

    // MARK: - Cluster Pruning

    static func pruneSmallClusters(_ image: NSImage, minPixels: Int = 50, iterations: Int = 6) -> NSImage? {
        OpenCVBridge.pruneSmallClusters(image, minPixelCount: Int32(minPixels), iterations: Int32(iterations))
    }

    // MARK: - Full PBN Pipeline (bilateral -> kmeans -> prune -> contours)

    struct PBNPipelineParams: Sendable {
        var numColors: Int = 10
        var bilateralD: Int = 21
        var sigmaColor: Double = 21
        var sigmaSpace: Double = 14
        var pruneMinPixels: Int = 50
        nonisolated init(numColors: Int = 10, bilateralD: Int = 21, sigmaColor: Double = 21, sigmaSpace: Double = 14, pruneMinPixels: Int = 50, pruneIterations: Int = 6) {
            self.numColors = numColors; self.bilateralD = bilateralD; self.sigmaColor = sigmaColor
            self.sigmaSpace = sigmaSpace; self.pruneMinPixels = pruneMinPixels; self.pruneIterations = pruneIterations
        }
        var pruneIterations: Int = 6
    }

    struct PBNPipelineResult {
        let colorImage: NSImage        // quantized + pruned
        let contourImage: NSImage      // black contours on white
        let palette: [(r: UInt8, g: UInt8, b: UInt8)]
    }

    static func paintByNumbersPipeline(
        _ source: NSImage,
        params: PBNPipelineParams = .init(),
        progress: @escaping (Double) -> Void
    ) async -> PBNPipelineResult? {
        await Task.detached(priority: .userInitiated) {
            // Step 1: Bilateral filter (smoothing)
            progress(0.0)
            guard let smoothed = OpenCVBridge.bilateralFilter(
                source,
                diameter: Int32(params.bilateralD),
                sigmaColor: params.sigmaColor,
                sigmaSpace: params.sigmaSpace
            ) else { return nil }
            progress(0.2)

            // Step 2: K-means quantization
            guard let quantResult = kmeansQuantize(smoothed, numColors: params.numColors) else { return nil }
            progress(0.5)

            // Step 3: Prune small clusters
            guard let pruned = pruneSmallClusters(
                quantResult.image,
                minPixels: params.pruneMinPixels,
                iterations: params.pruneIterations
            ) else { return nil }
            progress(0.7)

            // Step 4: Edge detection for contours
            guard let gray = OpenCVBridge.desaturate(pruned) else { return nil }
            progress(0.8)

            guard let edges = OpenCVBridge.cannyEdges(gray, threshold1: 30, threshold2: 90) else { return nil }
            progress(0.9)

            // Invert so contours are black on white
            guard let contourImage = OpenCVBridge.invert(edges) else { return nil }
            progress(1.0)

            return PBNPipelineResult(
                colorImage: pruned,
                contourImage: contourImage,
                palette: quantResult.palette
            )
        }.value
    }

    // MARK: - Filters

    static func bilateralFilter(
        _ source: NSImage,
        diameter: Int = 21,
        sigmaColor: Double = 21,
        sigmaSpace: Double = 14
    ) -> NSImage? {
        OpenCVBridge.bilateralFilter(source, diameter: Int32(diameter), sigmaColor: sigmaColor, sigmaSpace: sigmaSpace)
    }

    static func gaussianBlur(_ source: NSImage, sigma: Double = 3) -> NSImage? {
        OpenCVBridge.gaussianBlur(source, sigma: sigma)
    }

    static func medianBlur(_ source: NSImage, kernelSize: Int = 5) -> NSImage? {
        OpenCVBridge.medianBlur(source, kernelSize: Int32(kernelSize))
    }

    // MARK: - Color Operations

    static func desaturate(_ source: NSImage) -> NSImage? {
        OpenCVBridge.desaturate(source)
    }

    static func invert(_ source: NSImage) -> NSImage? {
        OpenCVBridge.invert(source)
    }

    static func colorDodgeBlend(base: NSImage, top: NSImage) -> NSImage? {
        OpenCVBridge.colorDodgeBlend(base, top: top)
    }

    static func adjustBrightnessContrast(_ source: NSImage, brightness: Double, contrast: Double) -> NSImage? {
        OpenCVBridge.adjustBrightnessContrast(source, brightness: brightness, contrast: contrast)
    }

    // MARK: - Edge Detection

    static func cannyEdges(_ source: NSImage, threshold1: Double = 50, threshold2: Double = 150) -> NSImage? {
        OpenCVBridge.cannyEdges(source, threshold1: threshold1, threshold2: threshold2)
    }

    static func laplacianEdges(_ source: NSImage) -> NSImage? {
        OpenCVBridge.laplacianEdges(source)
    }

    // MARK: - Morphology & Posterize

    static func posterize(_ source: NSImage, levels: Int) -> NSImage? {
        OpenCVBridge.posterize(source, levels: Int32(levels))
    }

    static func morphClose(_ mask: NSImage, kernelSize: Int = 5) -> NSImage? {
        OpenCVBridge.morphClose(mask, kernelSize: Int32(kernelSize))
    }

    static func morphOpen(_ mask: NSImage, kernelSize: Int = 5) -> NSImage? {
        OpenCVBridge.morphOpen(mask, kernelSize: Int32(kernelSize))
    }

    static func dilate(_ mask: NSImage, kernelSize: Int = 5) -> NSImage? {
        OpenCVBridge.dilate(mask, kernelSize: Int32(kernelSize))
    }

    static func erode(_ mask: NSImage, kernelSize: Int = 5) -> NSImage? {
        OpenCVBridge.erode(mask, kernelSize: Int32(kernelSize))
    }

    // MARK: - Contours

    struct ContourData {
        let points: [[CGPoint]]
    }

    static func findContours(_ binaryMask: NSImage) -> ContourData? {
        guard let rawContours = OpenCVBridge.findContours(binaryMask) else { return nil }
        let contours: [[CGPoint]] = rawContours.map { contour in
            contour.map { $0.pointValue }
        }
        return ContourData(points: contours)
    }

    // MARK: - Connected Components

    struct ComponentStats {
        let area: Int
        let boundingBox: CGRect
        let centroid: CGPoint
    }

    struct ConnectedComponentsResult {
        let count: Int
        let stats: [ComponentStats]
        let labelData: Data
    }

    static func connectedComponents(_ binaryMask: NSImage) -> ConnectedComponentsResult? {
        guard let dict = OpenCVBridge.connectedComponents(binaryMask) else { return nil }
        guard let count = (dict["count"] as? NSNumber)?.intValue,
              let labelData = dict["labelMap"] as? Data,
              let rawStats = dict["stats"] as? [[String: Any]] else {
            return nil
        }
        let stats: [ComponentStats] = rawStats.map { entry in
            let area = (entry["area"] as? NSNumber)?.intValue ?? 0
            let bbox = entry["boundingBox"] as? CGRect ?? .zero
            let centroid = entry["centroid"] as? CGPoint ?? .zero
            return ComponentStats(area: area, boundingBox: bbox, centroid: centroid)
        }
        return ConnectedComponentsResult(count: count, stats: stats, labelData: labelData)
    }

    // MARK: - Blending

    static func addWeighted(
        _ src1: NSImage,
        alpha: Double,
        _ src2: NSImage,
        beta: Double,
        gamma: Double = 0
    ) -> NSImage? {
        OpenCVBridge.addWeighted(src1, alpha: alpha, src2: src2, beta: beta, gamma: gamma)
    }

    static func multiplyBlend(base: NSImage, top: NSImage) -> NSImage? {
        OpenCVBridge.multiplyBlend(base, top: top)
    }

    // MARK: - Noise & Texture

    static func addGaussianNoise(_ source: NSImage, strength: Double = 8) -> NSImage? {
        OpenCVBridge.addGaussianNoise(source, strength: strength)
    }

    static func unsharpMask(_ source: NSImage, sigma: Double = 2, amount: Double = 1.5) -> NSImage? {
        OpenCVBridge.unsharpMask(source, sigma: sigma, amount: amount)
    }
}

// MARK: - PBNConfig Convenience

extension CVImageProcessor {

    /// Render a threshold map using a complete PBNConfig.
    /// Applies optional pre-blur and posterization before thresholding.
    static func thresholdMap(_ source: NSImage, config: PBNConfig) -> NSImage? {
        var working = source

        // Optional Gaussian pre-blur for smoother regions
        if config.blurRadius > 0 {
            guard let blurred = gaussianBlur(working, sigma: config.blurRadius) else { return nil }
            working = blurred
        }

        // Optional posterization before threshold mapping
        if config.posterizationLevels >= 2 {
            guard let posterized = posterize(working, levels: config.posterizationLevels) else { return nil }
            working = posterized
        }

        // Desaturate to grayscale for threshold mapping
        guard let gray = desaturate(working) else { return nil }

        return thresholdMap(gray, thresholds: config.thresholds, palette: config.palette)
    }
}
