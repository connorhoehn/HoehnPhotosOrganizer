import Foundation
import GRDB

// MARK: - LineageNode

/// A single node in the lineage display — can be a DB record (parent scan, frame extraction)
/// or an adjustment snapshot.
struct LineageNode: Identifiable {
    enum NodeKind {
        case assetOrigin(parentAssetId: String?, relationshipType: String)
        case adjustmentSnapshot(AdjustmentSnapshot)
        case pipelineOutput(pipelineRunId: String, stepName: String)
    }
    let id: String
    let kind: NodeKind
    let title: String
    let detail: String?
    let occurredAt: Date
    let photoAssetId: String
}

// MARK: - LineageRepository

/// Actor-based repository that reads parent/child/sibling relationships from `asset_lineage`
/// and the most-recent `ExtractionEvent` for a given photo.
///
/// Used by `FilmLineageSection` to populate the Film Lineage inspector panel (CP-2).
/// Also provides `fetchLineage` for the Phase 11 rollback / lineage timeline UI.
actor LineageRepository {

    private let dbPool: any DatabaseReader

    init(_ dbPool: any DatabaseReader) {
        self.dbPool = dbPool
    }

    // MARK: - Lineage timeline (Phase 11)

    /// Full ordered lineage for a photo: origin → adjustment snapshots, sorted by date.
    /// Pass an `AdjustmentSnapshotRepository` to include adjustment history.
    func fetchLineage(forPhoto photoId: String,
                      snapshotRepo: AdjustmentSnapshotRepository) async throws -> [LineageNode] {
        var nodes: [LineageNode] = []

        // 1. Origin: check asset_lineage for parent (async read — consistent with fetchSiblings)
        let lineageRow: Row? = try await dbPool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT parent_photo_id, operation, created_at
                FROM asset_lineage WHERE child_photo_id = ?
                LIMIT 1
            """, arguments: [photoId])
        }
        if let row = lineageRow {
            let parentId: String? = row["parent_photo_id"]
            let operation: String = row["operation"] ?? "derived"
            let createdAtStr: String = row["created_at"] ?? ""
            // GRDB stores dates as "YYYY-MM-DD HH:MM:SS.SSS" — try both formats
            let iso = ISO8601DateFormatter()
            let sqlite = DateFormatter()
            sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
            sqlite.locale = Locale(identifier: "en_US_POSIX")
            let createdAt = iso.date(from: createdAtStr)
                ?? sqlite.date(from: createdAtStr)
                ?? Date.distantPast
            nodes.append(LineageNode(
                id: "origin-\(photoId)",
                kind: .assetOrigin(
                    parentAssetId: parentId,
                    relationshipType: operation
                ),
                title: "Extracted from scan",
                detail: parentId.map { "Parent: \($0)" },
                occurredAt: createdAt,
                photoAssetId: photoId
            ))
        }

        // 2. Adjustment snapshots — load independently so origin still shows if this fails
        let snapshots = (try? await snapshotRepo.fetchSnapshots(forPhoto: photoId)) ?? []
        nodes += snapshots.map { snap in
            LineageNode(
                id: snap.id,
                kind: .adjustmentSnapshot(snap),
                title: snap.label ?? "Adjustment",
                detail: snap.isCurrentState ? "Current state" : nil,
                occurredAt: snap.createdAt,
                photoAssetId: photoId
            )
        }

        return nodes.sorted { $0.occurredAt < $1.occurredAt }
    }

    // MARK: - Parent

    /// Returns the parent `PhotoAsset` if this photo is a child frame in `asset_lineage`.
    /// Returns nil when the photo has no parent or the parent has been deleted.
    func fetchParent(for photoId: String) async throws -> PhotoAsset? {
        try await dbPool.read { db in
            // Find the lineage row where this photo is the child
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT parent_photo_id FROM asset_lineage
                    WHERE child_photo_id = ?
                    LIMIT 1
                """,
                arguments: [photoId]
            )
            guard let parentId: String = row?["parent_photo_id"] else { return nil }
            return try PhotoAsset.fetchOne(db, key: parentId)
        }
    }

    // MARK: - Siblings

    /// Returns sibling frames: other children sharing the same parent, excluding `photoId` itself.
    /// Returns an empty array when there is no parent or no siblings.
    func fetchSiblings(for photoId: String) async throws -> [PhotoAsset] {
        try await dbPool.read { db in
            // Resolve parent first
            let parentRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT parent_photo_id FROM asset_lineage
                    WHERE child_photo_id = ?
                    LIMIT 1
                """,
                arguments: [photoId]
            )
            guard let parentId: String = parentRow?["parent_photo_id"] else { return [] }

            // Fetch other children of that parent
            let siblingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT child_photo_id FROM asset_lineage
                    WHERE parent_photo_id = ? AND child_photo_id != ?
                    ORDER BY frame_index ASC
                """,
                arguments: [parentId, photoId]
            )
            let siblingIds = siblingRows.compactMap { $0["child_photo_id"] as String? }
            guard !siblingIds.isEmpty else { return [] }

            let placeholders = siblingIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT * FROM photo_assets
                WHERE id IN (\(placeholders))
                ORDER BY canonical_name ASC
            """
            return try PhotoAsset.fetchAll(db, sql: sql, arguments: StatementArguments(siblingIds))
        }
    }

    // MARK: - Children

    /// Returns child frames if this photo is a parent scan in `asset_lineage`.
    /// Returns an empty array when the photo has no children.
    func fetchChildren(for photoId: String) async throws -> [PhotoAsset] {
        try await dbPool.read { db in
            let childRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT child_photo_id FROM asset_lineage
                    WHERE parent_photo_id = ?
                    ORDER BY frame_index ASC
                """,
                arguments: [photoId]
            )
            let childIds = childRows.compactMap { $0["child_photo_id"] as String? }
            guard !childIds.isEmpty else { return [] }

            let placeholders = childIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT * FROM photo_assets
                WHERE id IN (\(placeholders))
                ORDER BY canonical_name ASC
            """
            return try PhotoAsset.fetchAll(db, sql: sql, arguments: StatementArguments(childIds))
        }
    }

    // MARK: - Extraction event

    /// Returns the most recent `ExtractionEvent` where `source_photo_id` matches `photoId`.
    /// Returns nil when no extraction has been recorded for this photo.
    func fetchExtractionEvent(for photoId: String) async throws -> ExtractionEvent? {
        try await dbPool.read { db in
            try ExtractionEvent
                .filter(Column("source_photo_id") == photoId)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    // MARK: - Name-pattern fallback (film series discovery)

    /// Finds the original scan and other frame/version photos by canonical name pattern.
    /// Strips trailing `_\d+` from the name to derive a base series name, then queries
    /// for photos sharing that prefix. Used when no formal asset_lineage records exist.
    ///
    /// Returns:
    ///   - `original`: the base scan (e.g. `img20260210_scan.tif`) when `photo` is a frame
    ///   - `versions`: other photos in the same series (frames, derivatives), excluding `photo`
    func fetchRelatedByBaseName(for photo: PhotoAsset) async throws -> (original: PhotoAsset?, versions: [PhotoAsset]) {
        let canonical = photo.canonicalName
        let noExt = (canonical as NSString).deletingPathExtension
        let ext   = (canonical as NSString).pathExtension

        // Strip trailing underscore + digits to find the series base name
        let base: String
        if let range = noExt.range(of: #"_\d+$"#, options: .regularExpression) {
            base = String(noExt[..<range.lowerBound])
        } else {
            base = noExt
        }
        let isFrame = base != noExt

        return try await dbPool.read { db in
            var original: PhotoAsset? = nil
            if isFrame {
                let origName = ext.isEmpty ? base : "\(base).\(ext)"
                original = try PhotoAsset
                    .filter(Column("canonical_name") == origName)
                    .fetchOne(db)
            }

            // All photos whose canonical_name starts with "{base}_" excluding the current photo
            let versions = try PhotoAsset
                .filter(Column("canonical_name").like("\(base)_%")
                    && Column("id") != photo.id)
                .order(Column("canonical_name").asc)
                .fetchAll(db)

            return (original, versions)
        }
    }

    // MARK: - Tool logs

    /// Returns ordered `ExtractionToolLog` rows for the given extraction event ID.
    /// Convenience wrapper so `FilmLineageSection` can stay thin.
    func fetchToolLogs(extractionId: String) async throws -> [ExtractionToolLog] {
        try await dbPool.read { db in
            try ExtractionToolLog
                .filter(Column("extraction_id") == extractionId)
                .order(Column("tool_order").asc)
                .fetchAll(db)
        }
    }
}
