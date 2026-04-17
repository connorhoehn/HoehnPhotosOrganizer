import Foundation
import GRDB
import os.log

// MARK: - Domain types

struct ConsolidationMove: Identifiable, Sendable {
    let id: String                // UUID
    let photoId: String
    let canonicalName: String
    let sourceDriveLabel: String
    let targetDriveLabel: String
    let fileSizeBytes: Int
}

struct ConsolidationPlan: Sendable {
    let id: String                // UUID
    let generatedAt: Date
    let photoCount: Int           // snapshot at generation time — used for staleness check
    let moves: [ConsolidationMove]
    let totalBytesToMove: Int
    let sourceDriveLabel: String
    let targetDriveLabel: String

    var isStale: Bool = false     // set by validateFreshness()
}

enum ConsolidationPlanError: Error {
    case staleLibrary(currentCount: Int, planCount: Int)
    case sourceAndTargetSame
    case sourceDriveNotFound(label: String)
    case targetDriveNotFound(label: String)
}

// MARK: - Service
// IMPORTANT: This service is simulation-only. It performs zero FileManager operations.
// All methods are read-only over the GRDB database.

actor ConsolidationPlanService {
    private let db: AppDatabase
    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "ConsolidationPlanService")

    init(db: AppDatabase) {
        self.db = db
    }

    /// Simulates moving all originals from sourceDriveLabel to targetDriveLabel.
    /// Returns a plan showing what would move — no FileManager calls.
    func generatePlan(
        sourceDriveLabel: String,
        targetDriveLabel: String
    ) async throws -> ConsolidationPlan {
        guard sourceDriveLabel != targetDriveLabel else {
            throw ConsolidationPlanError.sourceAndTargetSame
        }

        // Verify both drives exist
        let driveExists: (String) async throws -> Bool = { label in
            try await self.db.dbPool.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drives WHERE volume_label = ?", arguments: [label]) ?? 0
                return count > 0
            }
        }
        guard try await driveExists(sourceDriveLabel) else {
            throw ConsolidationPlanError.sourceDriveNotFound(label: sourceDriveLabel)
        }
        guard try await driveExists(targetDriveLabel) else {
            throw ConsolidationPlanError.targetDriveNotFound(label: targetDriveLabel)
        }

        // Snapshot: total photo count for staleness validation
        let photoCount: Int = try await db.dbPool.read { db in
            (try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM photo_assets")?["cnt"]) ?? 0
        }

        // Fetch all originals on source drive
        let candidates: [(String, String, Int)] = try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, canonical_name, file_size
                FROM photo_assets
                WHERE role = 'original'
                  AND file_path LIKE ?
                ORDER BY canonical_name ASC
            """, arguments: ["\(sourceDriveLabel)/%"])
            return rows.map { r in (r["id"] as String, r["canonical_name"] as String, r["file_size"] as Int) }
        }

        let moves = candidates.map { (photoId, canonicalName, fileSize) in
            ConsolidationMove(
                id: UUID().uuidString,
                photoId: photoId,
                canonicalName: canonicalName,
                sourceDriveLabel: sourceDriveLabel,
                targetDriveLabel: targetDriveLabel,
                fileSizeBytes: fileSize
            )
        }

        let plan = ConsolidationPlan(
            id: UUID().uuidString,
            generatedAt: .now,
            photoCount: photoCount,
            moves: moves,
            totalBytesToMove: moves.reduce(0) { $0 + $1.fileSizeBytes },
            sourceDriveLabel: sourceDriveLabel,
            targetDriveLabel: targetDriveLabel
        )
        logger.info("generatePlan: \(moves.count) moves planned from '\(sourceDriveLabel)' to '\(targetDriveLabel)'")
        return plan
    }

    /// Checks whether the plan is still valid (library hasn't changed since generation).
    /// Throws ConsolidationPlanError.staleLibrary if photo count has changed.
    func validateFreshness(plan: ConsolidationPlan) async throws {
        let currentCount: Int = try await db.dbPool.read { db in
            (try Row.fetchOne(db, sql: "SELECT COUNT(*) AS cnt FROM photo_assets")?["cnt"]) ?? 0
        }
        guard currentCount == plan.photoCount else {
            throw ConsolidationPlanError.staleLibrary(currentCount: currentCount, planCount: plan.photoCount)
        }
    }
}
