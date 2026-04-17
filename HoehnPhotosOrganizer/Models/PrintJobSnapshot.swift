import Foundation

/// Serializable snapshot of all Print Lab configuration needed to resume, duplicate,
/// or follow up on a print job. Stored as JSON in ActivityEvent.metadata for `printJob` events.
///
/// Captures everything the PrintLabViewModel needs to reconstruct the canvas:
/// - Paper dimensions, orientation, margins
/// - Template type and parameters
/// - ICC profile, rendering intent, color management
/// - Per-image placement (position, size, rotation, borders, curve adjustments)
/// - Printer settings (negative, 16-bit, flip emulsion)
/// - Soft proof settings
///
/// Images are referenced by photoAssetId — the proxy is loaded at restore time.
/// If the original photo is missing, restore fails gracefully with a message.
struct PrintJobSnapshot: Codable {

    // MARK: - Paper / Canvas

    var paperWidth: Double          // inches
    var paperHeight: Double
    var isPortrait: Bool
    var marginLeft: Double
    var marginRight: Double
    var marginTop: Double
    var marginBottom: Double

    // MARK: - Template

    var templateName: String?       // e.g. "Calibration Strip 4×2", "Digital Negative"
    var templateJSON: String?       // full PrintTemplate encoded as JSON (for exact restore)

    // MARK: - Color Management

    var colorMgmt: String           // "No Color Management" | "ColorSync Managed" | "Printer Manages Colors"
    var iccProfilePath: String?
    var iccProfileName: String?
    var renderingIntent: String?    // "relative" | "perceptual" | "absolute" | "saturation"
    var blackPointCompensation: Bool

    // MARK: - Printer Settings

    var printerName: String?
    var isNegative: Bool
    var is16Bit: Bool
    var simulateInkBlack: Bool
    var flipEmulsion: Bool

    // MARK: - Soft Proof

    var softProofEnabled: Bool
    var softProofProfilePath: String?
    var softProofIntent: String?    // same encoding as renderingIntent
    var softProofBPC: Bool

    // MARK: - Canvas Images

    var images: [ImagePlacement]

    struct ImagePlacement: Codable {
        var photoAssetId: String?   // nil = image was dropped from Finder (non-restorable)
        var canonicalName: String?  // for display when photo not found
        var positionX: Double       // inches
        var positionY: Double
        var width: Double           // inches
        var height: Double
        var rotation: Double        // degrees
        var aspectRatioLocked: Bool
        var borderWidthInches: Double
        var borderIsWhite: Bool
        var iccProfilePath: String? // per-image override
        var brightnessOffset: Double?
        var saturationOffset: Double?
        var tileLabel: String?
        var groupLabel: String?
    }

    // MARK: - Print Attempt Reference

    /// If this snapshot was created alongside a PrintAttempt, store the attempt ID
    /// so we can link to the full print outcome/notes.
    var printAttemptId: String?

    // MARK: - Encode/Decode helpers

    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(from json: String?) -> PrintJobSnapshot? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PrintJobSnapshot.self, from: data)
    }
}
