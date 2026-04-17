import Foundation

// MARK: - RegionalAdjustment

/// A structured regional adjustment from Sonnet's editorial critique response.
/// Maps to the `regional_adjustments` array in the EditorialFeedback JSON.
///
/// Flow: Apple Vision auto-segments → AdjustmentLayers stored in DB → labels sent to Sonnet →
/// Sonnet returns RegionalAdjustments keyed by region_label → matched back to AdjustmentLayers
/// and applied as PhotoAdjustments on each layer.
struct RegionalAdjustment: Codable, Equatable {
    let regionLabel: String
    let regionDescription: String
    let adjustments: SuggestedAdjustments
    let geometryHint: String?

    enum CodingKeys: String, CodingKey {
        case regionLabel = "region_label"
        case regionDescription = "region_description"
        case adjustments
        case geometryHint = "geometry_hint"
    }

    /// Convert Sonnet's suggested adjustments to a PhotoAdjustments snapshot
    /// suitable for applying to an AdjustmentLayer.
    func toPhotoAdjustments() -> PhotoAdjustments {
        var pa = PhotoAdjustments()
        if let v = adjustments.exposure   { pa.exposure   = v }
        if let v = adjustments.contrast   { pa.contrast   = v }
        if let v = adjustments.highlights { pa.highlights = v }
        if let v = adjustments.shadows    { pa.shadows    = v }
        if let v = adjustments.whites     { pa.whites     = v }
        if let v = adjustments.blacks     { pa.blacks     = v }
        if let v = adjustments.saturation { pa.saturation = v }
        if let v = adjustments.vibrance   { pa.vibrance   = v }
        return pa
    }
}
