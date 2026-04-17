import Foundation

// MARK: - PhotoAdjustments

/// Flat, Codable snapshot of every slider value in AdjustmentPanelView.
///
/// Stored as `adjustments_json` in `photo_assets` — the DB is the source of truth
/// for slider state. DNG/XMP output is a derivative export artifact.
///
/// Default values represent the identity (no adjustment applied).
struct PhotoAdjustments: Codable, Equatable {

    // MARK: Levels
    var exposure:   Double = 0      // –5.0 … +5.0 EV
    var contrast:   Int    = 0      // –100 … +100
    var highlights: Int    = 0      // –100 … +100
    var shadows:    Int    = 0      // –100 … +100
    var whites:     Int    = 0      // –100 … +100
    var blacks:     Int    = 0      // –100 … +100

    // MARK: White Balance
    var temperature: Double = 0     // –100 … +100 (maps to 3000K–10000K, neutral at 6500K)
    var tint:        Double = 0     // –100 … +100 (green ←→ magenta)

    // MARK: Color
    var saturation: Int    = 0      // –100 … +100
    var vibrance:   Int    = 0      // –100 … +100

    // MARK: Presence
    var clarity:    Double = 0      // –100 … +100 (local contrast via unsharp mask)
    var dehaze:     Double = 0      // –100 … +100 (shadow contrast + saturation boost)

    // MARK: Tone curve
    var useToneCurve:     Bool    = false
    var toneCurvePreset:  String? = nil   // ImageAdjustment.ToneCurvePreset.rawValue

    /// Interactive tone curve control points (input/output in 0…255).
    /// Empty means no custom curve; the default identity is [(0,0),(255,255)].
    var curvePoints: [CurvePoint]? = nil

    // MARK: Color Grading (tonal-zone hue/sat/lum)
    var colorGrading: ColorGrading = ColorGrading()

    // MARK: HSL (per-channel hue/saturation/luminance)
    var hsl: HSLAdjustments = HSLAdjustments()

    // MARK: Color Balance (per tonal zone R/G/B)
    var colorBalance: ColorBalance = ColorBalance()

    // MARK: Camera Calibration (primary hue/sat)
    var calibration: Calibration = Calibration()

    // MARK: Identity check

    var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 &&
        shadows  == 0 && whites   == 0 && blacks     == 0 &&
        temperature == 0 && tint == 0 &&
        saturation == 0 && vibrance == 0 &&
        clarity == 0 && dehaze == 0 && !useToneCurve && (curvePoints ?? []).isEmpty &&
        colorGrading == ColorGrading() && hsl == HSLAdjustments() &&
        colorBalance == ColorBalance() && calibration == Calibration()
    }
}

// MARK: - Nested colour types

extension PhotoAdjustments {

    struct TonalZone: Codable, Equatable {
        var hue:        Int = 0   // 0 … 360
        var saturation: Int = 0   // 0 … 100
        var luminance:  Int = 0   // –100 … +100
    }

    struct ColorGrading: Codable, Equatable {
        var shadows:    TonalZone = TonalZone()
        var midtones:   TonalZone = TonalZone()
        var highlights: TonalZone = TonalZone()
        var balance:    Int = 0   // –100 … +100
        var blending:   Int = 50  // 0 … 100
    }

    struct HSLChannel: Codable, Equatable {
        var hue:        Int = 0   // –100 … +100
        var saturation: Int = 0   // –100 … +100
        var luminance:  Int = 0   // –100 … +100
    }

    struct HSLAdjustments: Codable, Equatable {
        var red:     HSLChannel = HSLChannel()
        var orange:  HSLChannel = HSLChannel()
        var yellow:  HSLChannel = HSLChannel()
        var green:   HSLChannel = HSLChannel()
        var aqua:    HSLChannel = HSLChannel()
        var blue:    HSLChannel = HSLChannel()
        var purple:  HSLChannel = HSLChannel()
        var magenta: HSLChannel = HSLChannel()
    }

    struct RGBBalance: Codable, Equatable {
        var red:   Int = 0   // –100 … +100
        var green: Int = 0
        var blue:  Int = 0
    }

    struct ColorBalance: Codable, Equatable {
        var shadows:    RGBBalance = RGBBalance()
        var midtones:   RGBBalance = RGBBalance()
        var highlights: RGBBalance = RGBBalance()
    }

    struct PrimaryCalibration: Codable, Equatable {
        var hue:        Int = 0   // –100 … +100
        var saturation: Int = 0   // –100 … +100
    }

    struct Calibration: Codable, Equatable {
        var red:   PrimaryCalibration = PrimaryCalibration()
        var green: PrimaryCalibration = PrimaryCalibration()
        var blue:  PrimaryCalibration = PrimaryCalibration()
    }
}

// MARK: - JSON helpers

extension PhotoAdjustments {
    static func decode(from json: String) -> PhotoAdjustments? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhotoAdjustments.self, from: data)
    }

    func encodeToJSON() -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
