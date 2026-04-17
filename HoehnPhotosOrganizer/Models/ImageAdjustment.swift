import Foundation

// MARK: - ImageAdjustment

/// A single non-destructive image adjustment, stored as Codable parameters.
///
/// Persisted to XMP sidecars (Camera Raw / crs: namespace) and logged to
/// activity_log so every change to a file is traceable.
struct ImageAdjustment: Codable, Hashable, Identifiable {
    var id: String
    var type: AdjustmentType
    var appliedAt: String   // ISO8601
}

// MARK: - AdjustmentType

extension ImageAdjustment {
    enum AdjustmentType: Codable, Hashable {
        /// Composite tone curve — list of (input, output) points in [0, 255] range.
        case toneCurve(points: [CurvePoint])
        /// Lightroom-style tonal controls: blacks/whites/shadows/highlights in [-100, 100],
        /// exposure in [-5.0, +5.0].
        case levels(blacks: Int, whites: Int, shadows: Int, highlights: Int, exposure: Double)
        /// Simple one-knob controls: contrast/saturation/vibrance in [-100, 100].
        case basic(contrast: Int, saturation: Int, vibrance: Int)
    }
}

// MARK: - CurvePoint

struct CurvePoint: Codable, Hashable {
    var input: Int    // 0–255
    var output: Int   // 0–255
}

// MARK: - Convenience constructors

extension ImageAdjustment {
    static func toneCurve(_ points: [CurvePoint]) -> ImageAdjustment {
        ImageAdjustment(
            id: UUID().uuidString,
            type: .toneCurve(points: points),
            appliedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func levels(
        blacks: Int = 0,
        whites: Int = 0,
        shadows: Int = 0,
        highlights: Int = 0,
        exposure: Double = 0
    ) -> ImageAdjustment {
        ImageAdjustment(
            id: UUID().uuidString,
            type: .levels(blacks: blacks, whites: whites, shadows: shadows,
                          highlights: highlights, exposure: exposure),
            appliedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func basic(contrast: Int = 0, saturation: Int = 0, vibrance: Int = 0) -> ImageAdjustment {
        ImageAdjustment(
            id: UUID().uuidString,
            type: .basic(contrast: contrast, saturation: saturation, vibrance: vibrance),
            appliedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}

// MARK: - Preset tone curves

extension ImageAdjustment {
    enum ToneCurvePreset: String, CaseIterable, Identifiable {
        case linear         = "Linear"
        case mediumContrast = "Medium Contrast"
        case strongContrast = "Strong Contrast"

        var id: String { rawValue }

        var points: [CurvePoint] {
            switch self {
            case .linear:
                return [(0,0), (255,255)].map { CurvePoint(input: $0.0, output: $0.1) }
            case .mediumContrast:
                return [(0,0), (64,50), (128,131), (192,211), (255,255)].map {
                    CurvePoint(input: $0.0, output: $0.1)
                }
            case .strongContrast:
                return [(0,0), (64,43), (128,134), (192,218), (255,255)].map {
                    CurvePoint(input: $0.0, output: $0.1)
                }
            }
        }
    }
}

// MARK: - Display helpers

extension ImageAdjustment {
    /// Short human-readable label for activity log and inspector display.
    var displaySummary: String {
        switch type {
        case .toneCurve(let pts):
            return "Tone Curve (\(pts.count) points)"
        case .levels(let b, let w, let s, let h, let e):
            return "Levels — exp:\(String(format:"%.2f",e)) shadows:\(s) highlights:\(h) blacks:\(b) whites:\(w)"
        case .basic(let c, let sat, let v):
            return "Basic — contrast:\(c) sat:\(sat) vibrance:\(v)"
        }
    }
}
