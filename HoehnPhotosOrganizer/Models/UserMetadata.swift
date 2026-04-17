import Foundation

/// Canonical schema for `photo_assets.user_metadata_json`.
///
/// Fields are all optional so multiple lightweight workflows can each set a subset
/// and be non-destructively merged together.
struct UserMetadata: Codable {
    var camera: String?
    var lens: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: Int?
    var filmStock: String?
    var location: String?
    var latitude: Double?
    var longitude: Double?
    var date: String?
    var season: String?
    var lighting: String?
    var colorTemp: String?
    var keywords: [String]
    var people: [String]
    var occasion: String?
    var mood: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case camera, lens, aperture, location, latitude, longitude, date, season, lighting, keywords, people, occasion, mood, notes, iso
        case shutterSpeed = "shutter_speed"
        case filmStock    = "film_stock"
        case colorTemp    = "color_temp"
    }

    nonisolated init(
        camera: String? = nil, lens: String? = nil,
        aperture: String? = nil, shutterSpeed: String? = nil,
        iso: Int? = nil, filmStock: String? = nil,
        location: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        date: String? = nil, season: String? = nil,
        lighting: String? = nil, colorTemp: String? = nil,
        keywords: [String] = [], people: [String] = [],
        occasion: String? = nil, mood: String? = nil, notes: String? = nil
    ) {
        self.camera = camera; self.lens = lens
        self.aperture = aperture; self.shutterSpeed = shutterSpeed
        self.iso = iso; self.filmStock = filmStock
        self.location = location; self.latitude = latitude; self.longitude = longitude
        self.date = date; self.season = season
        self.lighting = lighting; self.colorTemp = colorTemp
        self.keywords = keywords; self.people = people
        self.occasion = occasion; self.mood = mood; self.notes = notes
    }

    // MARK: - Decode from JSON string

    static func decode(from json: String?) -> UserMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UserMetadata.self, from: data)
    }

    func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Non-destructive merge

    /// Returns a new `UserMetadata` where `other`'s non-nil fields overwrite ours.
    /// Existing fields not touched by `other` are preserved.
    func merging(_ other: UserMetadata) -> UserMetadata {
        var m = self
        if let v = other.camera       { m.camera       = v }
        if let v = other.lens         { m.lens         = v }
        if let v = other.aperture     { m.aperture     = v }
        if let v = other.shutterSpeed { m.shutterSpeed = v }
        if let v = other.iso          { m.iso          = v }
        if let v = other.filmStock    { m.filmStock    = v }
        if let v = other.location     { m.location     = v }
        if let v = other.latitude     { m.latitude     = v }
        if let v = other.longitude    { m.longitude    = v }
        if let v = other.date         { m.date         = v }
        if let v = other.season       { m.season       = v }
        if let v = other.lighting     { m.lighting     = v }
        if let v = other.colorTemp    { m.colorTemp    = v }
        if !other.keywords.isEmpty    { m.keywords     = Array(Set(m.keywords + other.keywords)) }
        if !other.people.isEmpty      { m.people       = other.people }
        if let v = other.occasion     { m.occasion     = v }
        if let v = other.mood         { m.mood         = v }
        if let v = other.notes        { m.notes        = v }
        return m
    }

    // MARK: - Display helpers

    /// Non-empty field rows for preview UI. Returns (label, value) pairs.
    var displayRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let v = location     { rows.append(("Location",      v)) }
        if let lat = latitude, let lon = longitude {
            rows.append(("GPS", String(format: "%.4f, %.4f", lat, lon)))
        }
        if let v = date         { rows.append(("Date",          v)) }
        if let v = season       { rows.append(("Season",        v)) }
        if let v = camera       { rows.append(("Camera",        v)) }
        if let v = lens         { rows.append(("Lens",          v)) }
        if let v = aperture     { rows.append(("Aperture",      v)) }
        if let v = shutterSpeed { rows.append(("Shutter",       v)) }
        if let v = iso          { rows.append(("ISO",           String(v))) }
        if let v = filmStock    { rows.append(("Film Stock",    v)) }
        if let v = lighting     { rows.append(("Lighting",      v)) }
        if let v = colorTemp    { rows.append(("Color Temp",    v)) }
        if !keywords.isEmpty    { rows.append(("Keywords",      keywords.joined(separator: ", "))) }
        if !people.isEmpty      { rows.append(("People",        people.joined(separator: ", "))) }
        if let v = occasion     { rows.append(("Occasion",      v)) }
        if let v = mood         { rows.append(("Mood",          v)) }
        if let v = notes        { rows.append(("Notes",         v)) }
        return rows
    }
}
