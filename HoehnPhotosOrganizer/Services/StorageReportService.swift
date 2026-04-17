import Foundation
import GRDB
import os.log

// MARK: - Domain types

struct DriveStorageBreakdown: Identifiable, Sendable {
    let id: String           // drives.id
    let volumeLabel: String
    let totalBytes: Int
    let freeBytes: Int
    let originalBytes: Int   // sum of file_size for role=original on this drive
    let proxyBytes: Int      // sum of byte_size for proxies linked to originals on this drive
    let derivativeBytes: Int // sum of file_size for workflow_output + edited_export + print_reference
}

struct StorageReport: Sendable {
    let generatedAt: Date
    let originalsBytes: Int       // all role=original file_size
    let proxiesBytes: Int         // all proxy_assets byte_size
    let derivativesBytes: Int     // workflow_output + edited_export + print_reference file_size
    let externalReferencesBytes: Int
    let driveBreakdowns: [DriveStorageBreakdown]
    var totalCataloggedBytes: Int {
        originalsBytes + proxiesBytes + derivativesBytes + externalReferencesBytes
    }
}

// MARK: - Service

actor StorageReportService {
    private let db: AppDatabase
    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "StorageReportService")

    init(db: AppDatabase) {
        self.db = db
    }

    func generateReport() async throws -> StorageReport {
        // Query 1: totals by role from photo_assets
        let roleTotals: [(String, Int)] = try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT role, COALESCE(SUM(file_size), 0) AS total
                FROM photo_assets
                GROUP BY role
            """)
            return rows.map { r in (r["role"] as String, r["total"] as Int) }
        }

        var originalsBytes = 0
        var derivativesBytes = 0
        var externalBytes = 0
        for (role, total) in roleTotals {
            switch role {
            case "original":                  originalsBytes = total
            case "workflow_output",
                 "edited_export",
                 "print_reference":           derivativesBytes += total
            case "external_reference":        externalBytes = total
            default: break
            }
        }

        // Query 2: total proxy bytes
        let proxiesBytes: Int = try await db.dbPool.read { db in
            (try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) AS total FROM proxy_assets")?["total"]) ?? 0
        }

        // Query 3: per-drive breakdown
        let driveBreakdowns = try await fetchDriveBreakdowns()

        return StorageReport(
            generatedAt: .now,
            originalsBytes: originalsBytes,
            proxiesBytes: proxiesBytes,
            derivativesBytes: derivativesBytes,
            externalReferencesBytes: externalBytes,
            driveBreakdowns: driveBreakdowns
        )
    }

    private func fetchDriveBreakdowns() async throws -> [DriveStorageBreakdown] {
        let drives: [(String, String, Int, Int)] = try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, volume_label, total_bytes, free_bytes FROM drives")
            return rows.map { r in (r["id"] as String, r["volume_label"] as String, r["total_bytes"] as Int, r["free_bytes"] as Int) }
        }

        var breakdowns: [DriveStorageBreakdown] = []
        for (driveId, label, totalBytes, freeBytes) in drives {
            // Photos whose file_path starts with the volume label
            let (origBytes, derivBytes): (Int, Int) = try await db.dbPool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT role, COALESCE(SUM(file_size), 0) AS total
                    FROM photo_assets
                    WHERE file_path LIKE ?
                    GROUP BY role
                """, arguments: ["\(label)/%"])
                var orig = 0, deriv = 0
                for row in rows {
                    let role = row["role"] as String
                    let t = row["total"] as Int
                    if role == "original" { orig = t }
                    else if ["workflow_output", "edited_export", "print_reference"].contains(role) { deriv += t }
                }
                return (orig, deriv)
            }

            let proxyBytes: Int = try await db.dbPool.read { db in
                (try Row.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(pr.byte_size), 0) AS total
                    FROM proxy_assets pr
                    JOIN photo_assets pa ON pa.id = pr.photo_id
                    WHERE pa.file_path LIKE ?
                """, arguments: ["\(label)/%"])?["total"]) ?? 0
            }

            breakdowns.append(DriveStorageBreakdown(
                id: driveId,
                volumeLabel: label,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                originalBytes: origBytes,
                proxyBytes: proxyBytes,
                derivativeBytes: derivBytes
            ))
        }
        return breakdowns
    }
}
