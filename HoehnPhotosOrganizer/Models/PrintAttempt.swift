import Foundation

struct PrintAttempt: Identifiable, Codable {
    var id: String
    var photoId: String                      // Source photo canonical_id
    var printType: PrintType
    var paper: String
    var outcome: PrintOutcome
    var outcomeNotes: String
    var curveFileId: String?                 // S3 curve file reference UUID
    var curveFileName: String?               // Original filename (e.g., "Density.acv")
    var printPhotoId: String?                // Optional: photo of finished print (FK to photo_assets)
    var createdAt: Date
    var updatedAt: Date
    var processSpecificFields: [String: AnyCodable]

    // MARK: ICC / Soft Proof fields (optional — nil for pre-ICC print records)

    var iccProfileName: String?              // e.g. "HahnemuleLusterFineArtPearl285China"
    var iccProfilePath: String?              // absolute path to .icc file
    var renderingIntent: String?             // "relative" | "perceptual" | "absolute" | "saturation"
    var blackPointCompensation: Bool?
    var brightnessCorrection: Double?        // offset applied before ICC (from saved correction)
    var saturationCorrection: Double?

    // MARK: Calibration grid fields (nil for single-image prints)

    /// Template name used, e.g. "Calibration Strip 4×2" or "8-up Proof Sheet".
    var calibrationTemplate: String?
    /// JSON-encoded array: [{index:0, brightness:0.1, saturation:0.0, label:"B +10%"}, …]
    var tileParametersJSON: String?
    /// 0-based index of the tile the user selected as the winner.
    var winnerTileIndex: Int?
    /// LLM-generated or user-entered notes from winner selection.
    var calibrationNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case photoId                 = "photo_id"
        case printType               = "print_type"
        case paper
        case outcome
        case outcomeNotes            = "outcome_notes"
        case curveFileId             = "curve_file_id"
        case curveFileName           = "curve_file_name"
        case printPhotoId            = "print_photo_id"
        case createdAt               = "created_at"
        case updatedAt               = "updated_at"
        case processSpecificFields   = "process_specific_fields"
        case iccProfileName          = "icc_profile_name"
        case iccProfilePath          = "icc_profile_path"
        case renderingIntent         = "rendering_intent"
        case blackPointCompensation  = "black_point_compensation"
        case brightnessCorrection    = "brightness_correction"
        case saturationCorrection    = "saturation_correction"
        case calibrationTemplate     = "calibration_template"
        case tileParametersJSON      = "tile_parameters_json"
        case winnerTileIndex         = "winner_tile_index"
        case calibrationNotes        = "calibration_notes"
    }
}

// Helper for JSON encoding of process fields
struct AnyCodable: Codable, Equatable, Hashable {
    var value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: AnyCodable] {
            try container.encode(dict)
        } else if let dict = value as? [String: Any] {
            let anyDictAsAnyCodable = dict.mapValues { AnyCodable($0) }
            try container.encode(anyDictAsAnyCodable)
        } else if let array = value as? [AnyCodable] {
            try container.encode(array)
        } else if let array = value as? [Any] {
            let anyArrayAsAnyCodable = array.map { AnyCodable($0) }
            try container.encode(anyArrayAsAnyCodable)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if value is NSNull {
            try container.encodeNil()
        } else {
            try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else {
            self.value = NSNull()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as NSNull, r as NSNull):
            return l == r
        case let (l as Bool, r as Bool):
            return l == r
        case let (l as Int, r as Int):
            return l == r
        case let (l as Double, r as Double):
            return l == r
        case let (l as String, r as String):
            return l == r
        case let (l as [String: AnyCodable], r as [String: AnyCodable]):
            return l == r
        case let (l as [AnyCodable], r as [AnyCodable]):
            return l == r
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch value {
        case let v as NSNull:
            hasher.combine(v)
        case let v as Bool:
            hasher.combine(v)
        case let v as Int:
            hasher.combine(v)
        case let v as Double:
            hasher.combine(v)
        case let v as String:
            hasher.combine(v)
        default:
            break
        }
    }
}
