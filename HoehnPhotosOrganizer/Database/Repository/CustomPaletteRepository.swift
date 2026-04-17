import Foundation
import GRDB

actor CustomPaletteRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    // MARK: - Palette CRUD

    /// Insert a new palette.
    func insertPalette(_ palette: CustomPalette) async throws {
        try await db.dbPool.write { db in
            var p = palette
            try p.insert(db)
        }
    }

    /// Update an existing palette (touches modifiedAt automatically).
    func updatePalette(_ palette: CustomPalette) async throws {
        try await db.dbPool.write { db in
            var p = palette.touchingModified()
            try p.update(db)
        }
    }

    /// Delete a palette and all of its colors.
    func deletePalette(id: String) async throws {
        try await db.dbPool.write { db in
            // Colors cascade-delete via FK, but be explicit for safety.
            try PaintColor
                .filter(PaintColor.Columns.paletteId == id)
                .deleteAll(db)
            _ = try CustomPalette.deleteOne(db, key: id)
        }
    }

    /// All palettes, newest first.
    func allPalettes() async throws -> [CustomPalette] {
        try await db.dbPool.read { db in
            try CustomPalette
                .order(CustomPalette.Columns.modifiedAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single palette by ID.
    func palette(id: String) async throws -> CustomPalette? {
        try await db.dbPool.read { db in
            try CustomPalette.fetchOne(db, key: id)
        }
    }

    // MARK: - Paint Color CRUD

    /// Insert a new paint color.
    func insertColor(_ color: PaintColor) async throws {
        try await db.dbPool.write { db in
            var c = color
            try c.insert(db)
        }
    }

    /// Update an existing paint color.
    func updateColor(_ color: PaintColor) async throws {
        try await db.dbPool.write { db in
            var c = color
            try c.update(db)
        }
    }

    /// Delete a single paint color by ID.
    func deleteColor(id: String) async throws {
        try await db.dbPool.write { db in
            _ = try PaintColor.deleteOne(db, key: id)
        }
    }

    /// All colors for a palette, ordered by sortOrder.
    func colorsForPalette(id paletteId: String) async throws -> [PaintColor] {
        try await db.dbPool.read { db in
            try PaintColor
                .filter(PaintColor.Columns.paletteId == paletteId)
                .order(PaintColor.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    /// Reorder colors within a palette. `colorIds` is the desired order;
    /// each color's `sortOrder` is set to its index in the array.
    func reorderColors(paletteId: String, colorIds: [String]) async throws {
        try await db.dbPool.write { db in
            for (index, colorId) in colorIds.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE paint_colors
                        SET sort_order = ?
                        WHERE id = ? AND palette_id = ?
                        """,
                    arguments: [index, colorId, paletteId]
                )
            }
        }
    }

    // MARK: - Convenience

    /// Fetch a palette together with all its colors (sorted by sortOrder).
    func paletteWithColors(id: String) async throws -> (CustomPalette, [PaintColor])? {
        try await db.dbPool.read { db in
            guard let palette = try CustomPalette.fetchOne(db, key: id) else {
                return nil
            }
            let colors = try PaintColor
                .filter(PaintColor.Columns.paletteId == id)
                .order(PaintColor.Columns.sortOrder.asc)
                .fetchAll(db)
            return (palette, colors)
        }
    }
}
