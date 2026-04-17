import AppKit

// MARK: - PenAndInkPipeline

/// Pen and ink: cannyEdges -> threshold to binary -> sharpen.
/// Produces cross-hatching, stippling, and line work in black ink on white paper.
enum PenAndInkPipeline: StudioPipeline {

    static let mediumName = "Pen & Ink"
    static let mediumIcon = "pencil.tip"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Edge sensitivity — controls Canny threshold pair.
        /// Lower values detect more edges (finer detail); higher values produce
        /// only the strongest contours. Range: 0–1, mapped to Canny t1/t2.
        var edgeSensitivity: Double
        /// Line weight — controls how thick/bold the ink strokes appear.
        /// Applied as Gaussian blur sigma before the final threshold (0–3).
        var lineWeight: Double
        /// Final contrast boost for crisp black-on-white rendering (0–2).
        var contrast: Double
    }

    static let defaultParams = Params(
        edgeSensitivity: 0.5,
        lineWeight: 1.0,
        contrast: 1.5
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Desaturate to grayscale for edge detection.
        // Pen and ink is a purely monochrome medium; we discard color first
        // so Canny operates on clean luminance data.
        guard let gray = CVImageProcessor.desaturate(source) else {
            throw PipelineError.renderStepFailed(step: "desaturate")
        }
        progress(0.10)
        try Task.checkCancellation()

        // Step 2: Canny edge detection.
        // This is the core of the pen-and-ink look: Canny finds luminance
        // discontinuities and produces thin, connected contour lines.
        // edgeSensitivity maps to the dual-threshold: low sensitivity = many edges,
        // high sensitivity = only strong edges.
        let t1 = 30.0 + params.edgeSensitivity * 100.0   // 30–130
        let t2 = 80.0 + params.edgeSensitivity * 170.0    // 80–250
        guard let edges = CVImageProcessor.cannyEdges(
            gray,
            threshold1: t1,
            threshold2: t2
        ) else {
            throw PipelineError.renderStepFailed(step: "cannyEdges")
        }
        progress(0.30)
        try Task.checkCancellation()

        // Step 3: Invert edges to get dark lines on white background.
        // Canny outputs white edges on black; pen-and-ink is black on white.
        guard let inverted = CVImageProcessor.invert(edges) else {
            throw PipelineError.renderStepFailed(step: "invert")
        }
        progress(0.42)
        try Task.checkCancellation()

        // Step 4: Thicken lines via slight blur for line weight.
        // Dip pens and technical pens produce varying line widths.
        // A small Gaussian blur fattens the 1px Canny lines, then the
        // threshold step snaps them back to crisp binary.
        guard let thickened = CVImageProcessor.gaussianBlur(
            inverted,
            sigma: params.lineWeight * 0.8
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (line weight)")
        }
        progress(0.55)
        try Task.checkCancellation()

        // Step 5: High-contrast threshold to binary black/white.
        // Pen and ink has no gray — only paper and ink. We push contrast
        // hard to snap every pixel to near-black or near-white.
        guard let binary = CVImageProcessor.adjustBrightnessContrast(
            thickened,
            brightness: 10.0,
            contrast: params.contrast * 1.5
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast (binary)")
        }
        progress(0.70)
        try Task.checkCancellation()

        // Step 6: Cross-hatch shadow layer.
        // Run a second Canny pass at lower sensitivity to pick up broader
        // shadow regions, then overlay as additional ink strokes for tonal depth.
        let shadowT1 = max(10.0, t1 * 0.5)
        let shadowT2 = max(30.0, t2 * 0.5)
        guard let shadowEdges = CVImageProcessor.cannyEdges(
            gray,
            threshold1: shadowT1,
            threshold2: shadowT2
        ) else {
            throw PipelineError.renderStepFailed(step: "cannyEdges (shadow)")
        }

        guard let shadowInverted = CVImageProcessor.invert(shadowEdges) else {
            throw PipelineError.renderStepFailed(step: "invert (shadow)")
        }
        progress(0.82)
        try Task.checkCancellation()

        // Multiply-blend the shadow hatch layer onto the primary lines.
        // Multiply preserves white and darkens where both layers have ink.
        guard let crossHatched = CVImageProcessor.multiplyBlend(
            base: binary,
            top: shadowInverted
        ) else {
            throw PipelineError.renderStepFailed(step: "multiplyBlend (cross-hatch)")
        }
        progress(0.90)
        try Task.checkCancellation()

        // Step 7: Final sharpen for crisp ink lines.
        guard let result = CVImageProcessor.unsharpMask(
            crossHatched,
            sigma: 0.8,
            amount: 1.5
        ) else {
            throw PipelineError.renderStepFailed(step: "unsharpMask (sharpen)")
        }
        progress(1.0)

        return result
    }
}
