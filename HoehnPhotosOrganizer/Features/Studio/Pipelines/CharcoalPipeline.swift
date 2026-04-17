import AppKit

// MARK: - CharcoalPipeline

/// Charcoal drawing: pencilSketch (low blur) -> dark-biased 5-zone threshold -> heavy noise -> directional smudge.
/// Produces deep blacks, soft gradations, and expressive marks on textured paper.
enum CharcoalPipeline: StudioPipeline {

    static let mediumName = "Charcoal"
    static let mediumIcon = "scribble"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Blur radius for pencil sketch extraction — kept low for coarse charcoal marks (1–40).
        var blurRadius: Double
        /// Four threshold values, biased dark so shadows dominate (0–255 each, ascending).
        var thresholds: [Int]
        /// Output contrast (50–200, maps to PencilSketchParams.contrast).
        var contrast: Double
        /// Paper roughness controlling noise texture intensity (0–1).
        var paperRoughness: Double
        /// Directional smudge amount simulating finger/stump blending (0–20).
        var smudgeAmount: Double
    }

    static let defaultParams = Params(
        blurRadius: 15.0,
        thresholds: [30, 70, 120, 175],
        contrast: 150.0,
        paperRoughness: 0.6,
        smudgeAmount: 6.0
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Pencil sketch with low blur radius.
        // Low blur preserves coarse, grainy marks characteristic of vine/compressed charcoal
        // rather than the fine lines of graphite.
        let sketchParams = CVImageProcessor.PencilSketchParams(
            blurRadius: params.blurRadius,
            brightness: -30,
            contrast: params.contrast,
            noiseStrength: 12,
            sharpAmount: 1.0
        )
        guard let sketch = CVImageProcessor.pencilSketch(source, params: sketchParams) else {
            throw PipelineError.renderStepFailed(step: "pencilSketch")
        }
        progress(0.15)
        try Task.checkCancellation()

        // Step 2: 5-zone threshold with dark-biased breakpoints.
        // Charcoal drawings have expansive dark masses with selective highlights.
        // The low thresholds (30, 70) create large dark regions; the higher thresholds
        // (120, 175) allow only the brightest areas to remain as paper white.
        let t = params.thresholds
        let zones: [CVImageProcessor.ThresholdZone] = [
            .init(lower: 0,      upper: t[0],  color: (r: 10,  g: 10,  b: 10)),   // deep charcoal black
            .init(lower: t[0],   upper: t[1],  color: (r: 50,  g: 48,  b: 46)),   // heavy charcoal
            .init(lower: t[1],   upper: t[2],  color: (r: 110, g: 106, b: 102)),  // mid charcoal
            .init(lower: t[2],   upper: t[3],  color: (r: 185, g: 180, b: 174)),  // light smudge
            .init(lower: t[3],   upper: 255,   color: (r: 238, g: 233, b: 226)),  // paper showing through
        ]
        guard let thresholded = CVImageProcessor.thresholdMap(
            sketch,
            zones: zones,
            backgroundColor: (r: 240, g: 235, b: 228)
        ) else {
            throw PipelineError.renderStepFailed(step: "thresholdMap")
        }
        progress(0.30)
        try Task.checkCancellation()

        // Step 3: Boost contrast for deep, velvety blacks.
        // Charcoal's hallmark is the range from absolute black to pure white.
        guard let contrasted = CVImageProcessor.adjustBrightnessContrast(
            thresholded,
            brightness: -10.0,
            contrast: 1.3
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast")
        }
        progress(0.45)
        try Task.checkCancellation()

        // Step 4: Heavy Gaussian noise to simulate charcoal grain on rough paper.
        // Real charcoal deposits unevenly on toothy paper, creating a speckled texture
        // where the paper peaks grab pigment and valleys stay white.
        guard let noisy = CVImageProcessor.addGaussianNoise(
            contrasted,
            strength: params.paperRoughness * 18.0
        ) else {
            throw PipelineError.renderStepFailed(step: "addGaussianNoise")
        }
        progress(0.60)
        try Task.checkCancellation()

        // Step 5: Directional smudge via Gaussian blur.
        // Simulates finger blending or tortillon work that charcoal artists use
        // to create soft gradations. The blur amount controls how much
        // marks are spread, softening hard threshold edges.
        guard let smudged = CVImageProcessor.gaussianBlur(
            noisy,
            sigma: params.smudgeAmount
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (smudge)")
        }
        progress(0.75)
        try Task.checkCancellation()

        // Step 6: Blend smudged result back with the noisy version.
        // Partial smudge: keep some hard marks (noisy) while softening others (smudged).
        // This prevents the drawing from looking uniformly blurry.
        guard let blended = CVImageProcessor.addWeighted(
            noisy,
            alpha: 0.4,
            smudged,
            beta: 0.6,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "addWeighted (smudge blend)")
        }
        progress(0.85)
        try Task.checkCancellation()

        // Step 7: Final paper texture layer.
        // Multiply-blend a noise texture to reinforce the paper tooth.
        guard let paperGrain = CVImageProcessor.addGaussianNoise(
            blended,
            strength: params.paperRoughness * 8.0
        ) else {
            throw PipelineError.renderStepFailed(step: "paper grain noise")
        }

        guard let result = CVImageProcessor.multiplyBlend(
            base: blended,
            top: paperGrain
        ) else {
            throw PipelineError.renderStepFailed(step: "multiplyBlend (paper)")
        }
        progress(1.0)

        return result
    }
}
