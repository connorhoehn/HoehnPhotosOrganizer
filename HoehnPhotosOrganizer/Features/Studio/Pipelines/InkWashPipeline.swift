import AppKit

// MARK: - InkWashPipeline

/// Ink wash (sumi-e): desaturate -> posterize (4–8 bands) -> gaussianBlur -> edge overlay -> rice paper.
/// Produces East Asian brush painting style with ink dilution for tonal range.
enum InkWashPipeline: StudioPipeline {

    static let mediumName = "Ink Wash"
    static let mediumIcon = "paintbrush"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Number of tonal bands (4–8). Each band represents a different ink dilution.
        /// Traditional sumi-e uses 5 values of ink (go-boku): dry, light, medium, dark, black.
        var numBands: Int
        /// Gaussian blur amount for soft ink-on-rice-paper bleeding (0–12).
        var blurAmount: Double
        /// Edge overlay strength for brush-stroke definition (0–1).
        var edgeStrength: Double
        /// Ink density — overall darkening factor (0–1).
        /// Higher values produce heavier, more saturated ink strokes.
        var inkDensity: Double
    }

    static let defaultParams = Params(
        numBands: 5,
        blurAmount: 4.0,
        edgeStrength: 0.5,
        inkDensity: 0.6
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Desaturate to grayscale.
        // Sumi-e uses only black ink (sumi) diluted with water for tonal range;
        // all color information is discarded.
        guard let gray = CVImageProcessor.desaturate(source) else {
            throw PipelineError.renderStepFailed(step: "desaturate")
        }
        progress(0.12)
        try Task.checkCancellation()

        // Step 2: Posterize into discrete tonal bands.
        // Each band represents a specific ink dilution level.
        // Traditional go-boku (five inks): dry brushwork, light wash,
        // medium wash, dark wash, solid black. We map numBands levels.
        guard let posterized = CVImageProcessor.posterize(
            gray,
            levels: params.numBands
        ) else {
            throw PipelineError.renderStepFailed(step: "posterize")
        }
        progress(0.28)
        try Task.checkCancellation()

        // Step 3: Gaussian blur for ink bleeding on absorbent rice paper.
        // Washi (rice paper) absorbs ink and causes it to feather outward,
        // softening hard edges into the characteristic diffused look of ink wash.
        guard let blurred = CVImageProcessor.gaussianBlur(
            posterized,
            sigma: params.blurAmount
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (ink bleed)")
        }
        progress(0.42)
        try Task.checkCancellation()

        // Step 4: Extract edges from the original for brush-stroke definition.
        // Sumi-e brushwork emphasizes expressive lines; Canny edges capture
        // the structural contours that the calligraphic brush would follow.
        guard let edges = CVImageProcessor.cannyEdges(
            gray,
            threshold1: 40.0,
            threshold2: 120.0
        ) else {
            throw PipelineError.renderStepFailed(step: "cannyEdges")
        }
        progress(0.55)
        try Task.checkCancellation()

        // Step 5: Invert edges (Canny produces white-on-black; we need dark strokes).
        guard let invertedEdges = CVImageProcessor.invert(edges) else {
            throw PipelineError.renderStepFailed(step: "invert (edges)")
        }
        progress(0.62)
        try Task.checkCancellation()

        // Step 6: Blend edges onto the washed base.
        // The edge overlay adds calligraphic line definition on top of the
        // soft tonal washes. edgeStrength controls the line prominence.
        guard let withEdges = CVImageProcessor.addWeighted(
            blurred,
            alpha: 1.0,
            invertedEdges,
            beta: params.edgeStrength,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "addWeighted (edge overlay)")
        }
        progress(0.72)
        try Task.checkCancellation()

        // Step 7: Adjust ink density.
        // Control overall darkness — heavier ink density pushes all tones darker,
        // simulating the difference between a light, airy landscape wash
        // and a dense, dramatic figure study.
        let brightness = -params.inkDensity * 25.0  // darken proportionally
        let contrast = 1.0 + params.inkDensity * 0.3
        guard let toned = CVImageProcessor.adjustBrightnessContrast(
            withEdges,
            brightness: brightness,
            contrast: contrast
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast (ink density)")
        }
        progress(0.85)
        try Task.checkCancellation()

        // Step 8: Rice paper texture.
        // Washi has a subtle warm fiber texture. We add light noise and blend
        // to simulate the paper's natural irregularity and warmth.
        guard let paperNoise = CVImageProcessor.addGaussianNoise(
            toned,
            strength: 0.06
        ) else {
            throw PipelineError.renderStepFailed(step: "rice paper noise")
        }

        guard let result = CVImageProcessor.addWeighted(
            toned,
            alpha: 0.88,
            paperNoise,
            beta: 0.12,
            gamma: 5.0  // slight warmth lift for rice paper tone
        ) else {
            throw PipelineError.renderStepFailed(step: "rice paper blend")
        }
        progress(1.0)

        return result
    }
}
