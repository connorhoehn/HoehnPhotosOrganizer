import Foundation

// MARK: - CurveGenerationError

enum CurveGenerationError: LocalizedError {
    case invalidFeedback(details: String)
    case curveGenerationFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .invalidFeedback(let details):
            return "Invalid feedback for curve generation: \(details)"
        case .curveGenerationFailed(let details):
            return "Curve generation failed: \(details)"
        }
    }
}

// MARK: - CurveData

/// A generated tone curve in a file-ready format.
struct CurveData: Codable {
    let id: String          // UUID
    let format: String      // "acv" | "csv"
    let data: Data          // Raw ACV bytes or CSV text
    let description: String // E.g., "Editorial feedback tone mapping"
    let createdAt: Date
}

// MARK: - CurveGenerationService

/// Actor that translates `EditorialFeedback` tone/exposure hints into a tone curve file.
///
/// This service is intentionally lightweight — the AI work is done by `EditorialCritiqueService`.
/// This service maps feedback keyword strings to curve control points and generates
/// a 256-point lookup table as either CSV (default) or ACV (Adobe Curve) format.
actor CurveGenerationService {

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Generate a tone curve from editorial feedback.
    ///
    /// Maps `feedback.toneAdjustments` and `feedback.exposureAdjustments` to curve parameters,
    /// then generates a 256-point tone curve in CSV format suitable for Photoshop import.
    ///
    /// - Parameter feedback: The `EditorialFeedback` from `EditorialCritiqueService`.
    /// - Returns: A `CurveData` with `format="csv"` (or `"acv"` if ACV encoding succeeds).
    func generateCurveFromFeedback(_ feedback: EditorialFeedback) async throws -> CurveData {
        // Derive tone parameters from numeric adjustments (primary) + masking hints (supplement)
        let params = parseToneParameters(
            adjustments: feedback.adjustments,
            maskingHints: feedback.maskingHints,
            compositionScore: feedback.compositionScore
        )

        // Generate 256-point curve
        let curvePoints = generateSCurve(
            shadowLift: params.shadowLift,
            shadowContrast: params.shadowContrast,
            highlightLift: params.highlightLift,
            blackPoint: params.blackPoint,
            whitePoint: params.whitePoint
        )

        // Encode as CSV
        let csvData = encodeAsCSV(curvePoints)

        return CurveData(
            id: UUID().uuidString,
            format: "csv",
            data: csvData,
            description: "Editorial feedback tone mapping",
            createdAt: .now
        )
    }

    // MARK: - Tone Parameter Parsing

    /// Parsed tone curve parameters derived from editorial feedback text hints.
    private struct ToneParameters {
        var shadowLift: Float = 0      // Raise shadows (0 = no change, positive = lift)
        var shadowContrast: Float = 0  // Add contrast in shadows (positive = more contrast)
        var highlightLift: Float = 0   // Raise/lower highlights (negative = recover)
        var blackPoint: Float = 0      // Raise/lower black point (positive = lift blacks)
        var whitePoint: Float = 255    // Raise/lower white point
    }

    private nonisolated func parseToneParameters(
        adjustments: SuggestedAdjustments?,
        maskingHints: [String],
        compositionScore: Int
    ) -> ToneParameters {
        var params = ToneParameters()

        // Apply numeric adjustments directly where possible
        if let adj = adjustments {
            if let shadows = adj.shadows   { params.shadowLift     = Float(shadows) / 400.0 }
            if let blacks = adj.blacks     { params.blackPoint      = Float(blacks) / 10.0 }
            if let highlights = adj.highlights { params.highlightLift = Float(highlights) / 10.0 }
            if let whites = adj.whites     { params.whitePoint     = 255 + Float(whites) / 2.0 }
            if let contrast = adj.contrast { params.shadowContrast = Float(contrast) / 200.0 }
        }

        let allHints = maskingHints.map { $0.lowercased() }

        for hint in allHints {
            // Shadow adjustments
            if hint.contains("contrast in shadows") || hint.contains("shadow contrast") {
                params.shadowContrast += 0.15
            }
            if hint.contains("lift black") || hint.contains("lift the black") || hint.contains("raise black") {
                params.blackPoint += 10
            }
            if hint.contains("crush black") || hint.contains("deepen shadow") {
                params.blackPoint -= 5
                params.shadowContrast += 0.05
            }
            if hint.contains("lift shadow") || hint.contains("open shadow") || hint.contains("raise shadow") {
                params.shadowLift += 0.1
            }

            // Highlight adjustments
            if hint.contains("reduce highlight") || hint.contains("recover highlight") || hint.contains("-") && hint.contains("highlight") {
                params.highlightLift -= 10
            }
            if hint.contains("boost highlight") || hint.contains("open highlight") {
                params.highlightLift += 5
            }
            if hint.contains("increase contrast") && !hint.contains("shadow") {
                // Overall S-curve: darken shadows, lift highlights
                params.shadowContrast += 0.1
                params.highlightLift += 5
                params.shadowLift -= 0.05
            }
            if hint.contains("overall contrast") || hint.contains("global contrast") {
                params.shadowContrast += 0.12
                params.highlightLift += 8
            }

            // Exposure adjustments
            if hint.contains("overexpos") || hint.contains("reduce exposure") {
                params.whitePoint -= 10
                params.highlightLift -= 8
            }
            if hint.contains("underexpos") || hint.contains("increase exposure") {
                params.whitePoint += 5
                params.shadowLift += 0.08
            }
        }

        // If no specific adjustments found, apply a subtle S-curve based on composition score
        let totalAdjustment = abs(params.shadowLift) + abs(params.shadowContrast) + abs(params.highlightLift)
        if totalAdjustment < 0.01 {
            // Mild S-curve: strength proportional to composition score (higher score = subtler adjustment)
            let strength = Float(max(1, 10 - compositionScore)) * 0.02
            params.shadowContrast = strength
            params.highlightLift = strength * 5
        }

        return params
    }

    // MARK: - Curve Generation

    /// Generate a 256-point tone curve using the given parameters.
    ///
    /// - Parameters:
    ///   - shadowLift: Raise the lower quarter of the curve (0–63 input range).
    ///   - shadowContrast: Steepen the curve in the shadow-to-midtone range.
    ///   - highlightLift: Shift the upper quarter of the curve up or down.
    ///   - blackPoint: Offset the zero-point (x=0) output.
    ///   - whitePoint: Target output for x=255.
    /// - Returns: 256 Float values in [0, 255] range (output for each input 0–255).
    nonisolated func generateSCurve(
        shadowLift: Float,
        shadowContrast: Float,
        highlightLift: Float,
        blackPoint: Float,
        whitePoint: Float
    ) -> [Float] {
        var curve = [Float](repeating: 0, count: 256)

        let clampedBlack = max(0, min(30, blackPoint))
        let clampedWhite = max(225, min(255, whitePoint))

        for x in 0..<256 {
            let t = Float(x) / 255.0  // Normalized 0..1

            // Base linear output scaled between blackPoint and whitePoint
            var y = clampedBlack + t * (clampedWhite - clampedBlack)

            // Shadow region (t < 0.5): apply shadow contrast and lift
            if t < 0.5 {
                let shadowT = t / 0.5  // Remap shadow region to 0..1
                let shadowBoost = shadowContrast * shadowT * (1 - shadowT) * 4 * 30
                y += shadowBoost
                y += shadowLift * Float(x)
            }

            // Highlight region (t > 0.5): apply highlight shift
            if t > 0.5 {
                let highlightT = (t - 0.5) / 0.5  // Remap highlight region to 0..1
                y += highlightLift * highlightT
            }

            curve[x] = max(0, min(255, y))
        }

        return curve
    }

    // MARK: - Encoding

    /// Encode a 256-point curve as CSV (tab-separated x<TAB>y pairs, one per line).
    /// Compatible with Photoshop "Load Curves Preset" CSV import.
    private nonisolated func encodeAsCSV(_ curve: [Float]) -> Data {
        var lines = [String]()
        for (x, y) in curve.enumerated() {
            lines.append("\(x)\t\(Int(y.rounded()))")
        }
        let csv = lines.joined(separator: "\n")
        return Data(csv.utf8)
    }
}
