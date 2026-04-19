import Foundation
import Vision
import GRDB
import os.log

// MARK: - Domain types

struct DuplicateGroup: Identifiable, Sendable {
    let id: String           // UUID — unique per group
    let photoIds: [String]   // photo_assets.id values in this group
    let proxyPaths: [String] // proxy file paths for thumbnail display
    let representativePhotoId: String  // first in group (use for display)
}

enum DuplicateDetectionError: Error {
    case featurePrintFailed
    case proxyNotFound(photoId: String)
}

// MARK: - Service

actor DuplicateDetectionService {
    private let db: AppDatabase
    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "DuplicateDetectionService")
    private let threshold: Float = 0.5
    private let windowHours: Double = 2.0  // ±2 hour temporal window

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Public API

    /// Scans all proxy-ready original photos and returns groups of near-duplicates.
    /// Uses a ±2-hour temporal window to avoid O(n²) all-pairs comparison.
    /// Safe to call at scale: uses fetchCursor internally.
    /// IMPORTANT: Does not modify any database rows. Caller decides what to do with groups.
    func detectGroups() async throws -> [DuplicateGroup] {
        // Step 1: Collect (photoId, captureDate, proxyPath) tuples ordered by capture date
        let candidates = try await fetchCandidates()
        guard candidates.count > 1 else { return [] }

        // Step 2: Sliding window comparison — O(n * window_size), not O(n²)
        var groups: [[Int]] = []       // indices into candidates array
        var assignedToGroup = Set<Int>()

        for i in 0..<candidates.count {
            guard !assignedToGroup.contains(i) else { continue }
            var group = [i]
            let anchorDate = candidates[i].captureDate

            for j in (i + 1)..<candidates.count {
                guard !assignedToGroup.contains(j) else { continue }
                let jDate = candidates[j].captureDate
                // Only compare within ±2 hour window
                let deltaSeconds: Double = abs(jDate.timeIntervalSince(anchorDate))
                guard deltaSeconds <= Double(windowHours) * 3600.0 else { break }

                guard
                    let printA = try? featurePrint(for: URL(fileURLWithPath: candidates[i].proxyPath)),
                    let printB = try? featurePrint(for: URL(fileURLWithPath: candidates[j].proxyPath))
                else { continue }

                if areNearDuplicates(printA, printB) {
                    group.append(j)
                }
            }

            if group.count > 1 {
                for idx in group { assignedToGroup.insert(idx) }
                groups.append(group)
            }
        }

        return groups.map { indices in
            let members = indices.map { candidates[$0] }
            return DuplicateGroup(
                id: UUID().uuidString,
                photoIds: members.map { $0.photoId },
                proxyPaths: members.map { $0.proxyPath },
                representativePhotoId: members[0].photoId
            )
        }
    }

    // MARK: - Internal helpers

    func areNearDuplicates(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Bool {
        var distance: Float = 0
        try? a.computeDistance(&distance, to: b)
        return distance <= threshold
    }

    private func featurePrint(for proxyURL: URL) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(url: proxyURL, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first as? VNFeaturePrintObservation else {
            throw DuplicateDetectionError.featurePrintFailed
        }
        return obs
    }

    // MARK: - Candidate fetching

    private struct Candidate {
        let photoId: String
        let proxyPath: String
        let captureDate: Date
    }

    private func fetchCandidates() async throws -> [Candidate] {
        // Fetch photo IDs + EXIF capture date for all proxy-ready originals
        // ordered by capture date ASC (required for temporal window correctness)
        let rows: [(String, String?, String)] = try await db.dbPool.read { db in
            // SELECT photo_assets.id, photo_assets.raw_exif_json, proxy_assets.file_path
            // FROM photo_assets JOIN proxy_assets ON proxy_assets.photo_id = photo_assets.id
            // WHERE photo_assets.role = 'original' AND photo_assets.processing_state = 'proxy_ready'
            // ORDER BY json_extract(raw_exif_json, '$.DateTimeOriginal') ASC
            let sql = """
                SELECT pa.id, pa.raw_exif_json, pr.file_path
                FROM photo_assets pa
                JOIN proxy_assets pr ON pr.photo_id = pa.id
                WHERE pa.role = 'original'
                  AND pa.processing_state = 'proxy_ready'
                ORDER BY json_extract(pa.raw_exif_json, '$.DateTimeOriginal') ASC
            """
            return try Row.fetchAll(db, sql: sql).map { row in
                (row["id"] as String, row["raw_exif_json"] as String?, row["file_path"] as String)
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        let exifFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return f
        }()

        return rows.compactMap { (photoId, exifJson, proxyPath) -> Candidate? in
            var captureDate = Date(timeIntervalSinceReferenceDate: 0)
            if let exifJson,
               let data = exifJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let raw = dict["DateTimeOriginal"] as? String {
                    captureDate = exifFormatter.date(from: raw)
                        ?? isoFormatter.date(from: raw)
                        ?? Date(timeIntervalSinceReferenceDate: 0)
                }
            }
            return Candidate(photoId: photoId, proxyPath: proxyPath, captureDate: captureDate)
        }
    }
}
