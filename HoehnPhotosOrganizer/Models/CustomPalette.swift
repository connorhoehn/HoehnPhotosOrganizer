import Foundation
import GRDB

// MARK: - PaintMedium

enum PaintMedium: String, Codable, CaseIterable {
    case oil = "Oil"
    case watercolor = "Watercolor"
    case acrylic = "Acrylic"
    case gouache = "Gouache"
    case pastel = "Pastel"
}

// MARK: - PaintTransparency

enum PaintTransparency: String, Codable, CaseIterable {
    case transparent = "Transparent"
    case semiTransparent = "Semi-Transparent"
    case semiOpaque = "Semi-Opaque"
    case opaque = "Opaque"
}

// MARK: - PaintColor

struct PaintColor: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "paint_colors"

    var id: String
    var paletteId: String
    var name: String           // "Ultramarine Blue"
    var brand: String?         // "Winsor & Newton"
    var red: Double            // 0-1
    var green: Double          // 0-1
    var blue: Double           // 0-1
    var pigmentCode: String?   // "PB29"
    var medium: String         // PaintMedium raw value
    var transparency: String   // PaintTransparency raw value
    var sortOrder: Int

    enum Columns: String, ColumnExpression {
        case id
        case paletteId = "palette_id"
        case name
        case brand
        case red, green, blue
        case pigmentCode = "pigment_code"
        case medium
        case transparency
        case sortOrder = "sort_order"
    }

    // MARK: - Convenience Initializer

    init(
        id: String = UUID().uuidString,
        paletteId: String,
        name: String,
        brand: String? = nil,
        red: Double,
        green: Double,
        blue: Double,
        pigmentCode: String? = nil,
        medium: PaintMedium,
        transparency: PaintTransparency,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.paletteId = paletteId
        self.name = name
        self.brand = brand
        self.red = red
        self.green = green
        self.blue = blue
        self.pigmentCode = pigmentCode
        self.medium = medium.rawValue
        self.transparency = transparency.rawValue
        self.sortOrder = sortOrder
    }

    // MARK: - Computed Properties

    var paintMedium: PaintMedium? {
        PaintMedium(rawValue: medium)
    }

    var paintTransparency: PaintTransparency? {
        PaintTransparency(rawValue: transparency)
    }
}

// MARK: - CustomPalette

struct CustomPalette: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "custom_palettes"

    var id: String
    var name: String           // "My Watercolor Palette"
    var createdAt: String      // ISO8601
    var modifiedAt: String     // ISO8601

    enum Columns: String, ColumnExpression {
        case id
        case name
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    // MARK: - Convenience Initializer

    init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = ISO8601DateFormatter().string(from: createdAt)
        self.modifiedAt = ISO8601DateFormatter().string(from: modifiedAt)
    }

    // MARK: - Computed Properties

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    var modifiedDate: Date? {
        ISO8601DateFormatter().date(from: modifiedAt)
    }

    /// Returns a copy with `modifiedAt` set to now.
    func touchingModified() -> CustomPalette {
        var copy = self
        copy.modifiedAt = ISO8601DateFormatter().string(from: Date())
        return copy
    }
}
