import Foundation

// MARK: - ICCProfileCorrection

struct ICCProfileCorrection: Codable, Identifiable {
    var id: UUID
    var profilePath: String
    var profileDisplayName: String
    var printer: String
    var renderingIntent: String           // "relative" | "perceptual" | "absolute" | "saturation"
    var brightnessOffset: Double
    var saturationOffset: Double
    var dateCalibrated: Date
    var sourceJobID: String?
    var notes: String

    enum CodingKeys: String, CodingKey {
        case id
        case profilePath         = "profile_path"
        case profileDisplayName  = "profile_display_name"
        case printer
        case renderingIntent     = "rendering_intent"
        case brightnessOffset    = "brightness_offset"
        case saturationOffset    = "saturation_offset"
        case dateCalibrated      = "date_calibrated"
        case sourceJobID         = "source_job_id"
        case notes
    }
}

// MARK: - ICCProfileCorrectionStore

/// Persists ICC profile calibration corrections to
/// ~/Library/Application Support/HoehnPhotosOrganizer/PrintCorrections.json.
/// One correction entry per profilePath — saving a new one replaces the old.
actor ICCProfileCorrectionStore {

    static let shared = ICCProfileCorrectionStore()

    private var corrections: [ICCProfileCorrection] = []
    private var loaded = false

    private static var storeURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("PrintCorrections.json")
    }

    // MARK: Public API

    func correction(forProfilePath path: String) throws -> ICCProfileCorrection? {
        try ensureLoaded()
        return corrections.first { $0.profilePath == path }
    }

    func allCorrections() throws -> [ICCProfileCorrection] {
        try ensureLoaded()
        return corrections
    }

    func save(_ correction: ICCProfileCorrection) throws {
        try ensureLoaded()
        corrections.removeAll { $0.profilePath == correction.profilePath }
        corrections.append(correction)
        try persist()
    }

    func remove(forProfilePath path: String) throws {
        try ensureLoaded()
        corrections.removeAll { $0.profilePath == path }
        try persist()
    }

    // MARK: Private

    private func ensureLoaded() throws {
        guard !loaded else { return }
        let url = Self.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            corrections = []
            loaded = true
            return
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        corrections = try decoder.decode([ICCProfileCorrection].self, from: data)
        loaded = true
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(corrections)
        let url = Self.storeURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
