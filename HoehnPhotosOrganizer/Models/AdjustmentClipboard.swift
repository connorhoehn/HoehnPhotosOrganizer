import Foundation
import Observation

/// Specifies which parameter groups to paste when applying a copied adjustment.
struct PasteOptions: Codable {
    var tone: Bool         = true  // exposure, contrast, highlights, shadows, whites, blacks
    var color: Bool        = true  // saturation, vibrance
    var curves: Bool       = true  // useToneCurve, toneCurvePreset
    var hsl: Bool          = true
    var colorGrading: Bool = true
    var colorBalance: Bool = true
    var calibration: Bool  = true

    static let all = PasteOptions()
    static let toneOnly = PasteOptions(tone: true, color: false, curves: false, hsl: false, colorGrading: false, colorBalance: false, calibration: false)
    static let gradeOnly = PasteOptions(tone: false, color: false, curves: true, hsl: true, colorGrading: true, colorBalance: true, calibration: true)

    var anySelected: Bool { tone || color || curves || hsl || colorGrading || colorBalance || calibration }
}

/// In-memory clipboard for copied photo adjustments.
/// Inject into SwiftUI environment as a singleton.
@Observable
final class AdjustmentClipboard {
    var copiedAdjustment: PhotoAdjustments?
    var sourcePhotoId: String?
    var hasContent: Bool { copiedAdjustment != nil }

    func copy(adjustment: PhotoAdjustments, fromPhoto photoId: String) {
        copiedAdjustment = adjustment
        sourcePhotoId = photoId
    }

    func clear() {
        copiedAdjustment = nil
        sourcePhotoId = nil
    }

    /// Build a merged adjustment: source fields filtered by PasteOptions overlaid onto the target's existing state.
    func buildAdjustment(for target: PhotoAdjustments, options: PasteOptions) -> PhotoAdjustments? {
        guard let source = copiedAdjustment else { return nil }
        var result = target

        if options.tone {
            result.exposure   = source.exposure
            result.contrast   = source.contrast
            result.highlights = source.highlights
            result.shadows    = source.shadows
            result.whites     = source.whites
            result.blacks     = source.blacks
        }
        if options.color {
            result.saturation = source.saturation
            result.vibrance   = source.vibrance
        }
        if options.curves {
            result.useToneCurve    = source.useToneCurve
            result.toneCurvePreset = source.toneCurvePreset
        }
        if options.hsl {
            result.hsl = source.hsl
        }
        if options.colorGrading {
            result.colorGrading = source.colorGrading
        }
        if options.colorBalance {
            result.colorBalance = source.colorBalance
        }
        if options.calibration {
            result.calibration = source.calibration
        }

        return result
    }
}
