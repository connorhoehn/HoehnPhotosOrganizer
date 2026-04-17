import AppKit

// MARK: - OilPaintPipeline

/// Oil painting: bilateralFilter -> kmeans quantize -> prune small clusters -> palette map -> canvas texture.
/// Produces rich, textured brushstrokes with visible impasto and blended edges.
enum OilPaintPipeline: StudioPipeline {

    static let mediumName = "Oil Painting"
    static let mediumIcon = "drop.fill"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Number of dominant colors to extract via k-means (4–24).
        var numColors: Int
        /// Bilateral filter diameter — larger = more paint-like smoothing (5–25).
        var bilateralD: Int
        /// Bilateral filter color sigma — higher = more color blending across edges (20–150).
        var sigmaColor: Double
        /// Bilateral filter spatial sigma — higher = smoother spatial regions (20–150).
        var sigmaSpace: Double
        /// Minimum pixel count for a color cluster to survive pruning.
        /// Small clusters get absorbed into neighboring regions.
        var pruneMinPixels: Int
        /// Canvas/brush texture overlay strength (0–1).
        var brushTexture: Double
    }

    static let defaultParams = Params(
        numColors: 12,
        bilateralD: 15,
        sigmaColor: 75.0,
        sigmaSpace: 75.0,
        pruneMinPixels: 200,
        brushTexture: 0.5
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        var stepStart = pipelineStart
        let w = Int(source.size.width), h = Int(source.size.height)
        print("[OilPipeline] Start: \(w)x\(h), colors=\(params.numColors), bilateral=\(params.bilateralD), prune=\(params.pruneMinPixels)")
        progress(0.0)

        // Step 1: Bilateral filter
        guard let smoothed = CVImageProcessor.bilateralFilter(
            source,
            diameter: params.bilateralD,
            sigmaColor: params.sigmaColor,
            sigmaSpace: params.sigmaSpace
        ) else {
            throw PipelineError.renderStepFailed(step: "bilateralFilter")
        }
        var now = CFAbsoluteTimeGetCurrent()
        print("[OilPipeline] Step 1 bilateral: \(String(format: "%.2f", now - stepStart))s")
        stepStart = now
        progress(0.20)
        try Task.checkCancellation()

        // Step 2: K-means quantization (GPU when available, CPU fallback)
        let quantizedImage: NSImage
        if let metal = MetalImageProcessor.shared,
           let metalResult = metal.kmeansQuantize(smoothed, numColors: params.numColors, iterations: 12) {
            quantizedImage = metalResult
            now = CFAbsoluteTimeGetCurrent()
            print("[OilPipeline] Step 2 kmeans(\(params.numColors)) [Metal GPU]: \(String(format: "%.2f", now - stepStart))s")
        } else if let cpuResult = CVImageProcessor.kmeansQuantize(smoothed, numColors: params.numColors) {
            quantizedImage = cpuResult.image
            now = CFAbsoluteTimeGetCurrent()
            print("[OilPipeline] Step 2 kmeans(\(params.numColors)) [CPU]: \(String(format: "%.2f", now - stepStart))s")
        } else {
            throw PipelineError.renderStepFailed(step: "kmeansQuantize")
        }
        stepStart = now
        progress(0.45)
        try Task.checkCancellation()

        // Step 3: Prune small clusters
        guard let pruned = CVImageProcessor.pruneSmallClusters(
            quantizedImage,
            minPixels: params.pruneMinPixels,
            iterations: 3
        ) else {
            throw PipelineError.renderStepFailed(step: "pruneSmallClusters")
        }
        now = CFAbsoluteTimeGetCurrent()
        print("[OilPipeline] Step 3 prune: \(String(format: "%.2f", now - stepStart))s")
        stepStart = now
        progress(0.60)
        try Task.checkCancellation()

        // Step 4: Light bilateral blend pass
        guard let blended = CVImageProcessor.bilateralFilter(
            pruned,
            diameter: max(5, params.bilateralD / 2),
            sigmaColor: params.sigmaColor * 0.5,
            sigmaSpace: params.sigmaSpace * 0.5
        ) else {
            throw PipelineError.renderStepFailed(step: "bilateralFilter (blend pass)")
        }
        now = CFAbsoluteTimeGetCurrent()
        print("[OilPipeline] Step 4 bilateral2: \(String(format: "%.2f", now - stepStart))s")
        stepStart = now
        progress(0.75)
        try Task.checkCancellation()

        // Step 5: Contrast boost
        guard let vivid = CVImageProcessor.adjustBrightnessContrast(
            blended,
            brightness: 5.0,
            contrast: 1.15
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast")
        }
        now = CFAbsoluteTimeGetCurrent()
        print("[OilPipeline] Step 5 contrast: \(String(format: "%.2f", now - stepStart))s")
        stepStart = now
        progress(0.85)
        try Task.checkCancellation()

        // Step 6: Canvas texture overlay
        guard let canvasNoise = CVImageProcessor.addGaussianNoise(
            vivid,
            strength: params.brushTexture * 0.12
        ) else {
            throw PipelineError.renderStepFailed(step: "canvas noise")
        }

        guard let result = CVImageProcessor.addWeighted(
            vivid,
            alpha: 1.0 - params.brushTexture * 0.3,
            canvasNoise,
            beta: params.brushTexture * 0.3,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "canvas texture blend")
        }
        now = CFAbsoluteTimeGetCurrent()
        print("[OilPipeline] Step 6 texture: \(String(format: "%.2f", now - stepStart))s")
        progress(1.0)

        print("[StudioRender] ✓ DONE Oil Painting in \(String(format: "%.2f", now - pipelineStart))s → \(w)×\(h)")

        return result
    }
}
