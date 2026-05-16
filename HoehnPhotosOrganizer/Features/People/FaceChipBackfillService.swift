import Foundation
import GRDB

/// One-shot job that scans `face_embeddings` for rows lacking an on-disk chip and
/// generates the missing chips in bounded-parallel batches.
///
/// Used at app launch to bring legacy face rows (indexed before the chip-store
/// architecture landed) up to par. Also self-heals after a crash mid-indexing: any
/// face whose chip didn't get flushed will get generated here on the next launch.
///
/// Idempotent — re-running over a fully-backfilled DB does only `fileExists` checks
/// and returns quickly.
struct FaceChipBackfillService {

    /// Bounded concurrency. CoreML/ImageIO decode is CPU-bound for JPEG proxies and
    /// I/O-bound for RAW source files; 4 in flight is a sweet spot on Apple Silicon
    /// where we don't want to starve the UI or other background work.
    static let maxConcurrent: Int = 4

    /// Continuation callback for progress reporting. Called with (completed, total).
    typealias ProgressHandler = @Sendable (Int, Int) -> Void

    let db: AppDatabase

    /// Returns the face IDs that exist in the DB. Useful both for `runIfNeeded` and
    /// for the GC pass that runs alongside it (caller can fetch once, use twice).
    func fetchAllFaceIds() async throws -> Set<String> {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: "SELECT id FROM face_embeddings")
            return Set(rows.map { $0["id"] as String })
        }
    }

    /// Generate any missing face chips. Returns `(generated, skipped)`.
    ///
    /// - Parameters:
    ///   - progress: called on the run's caller-task isolation as each chip lands.
    ///     `total` is the count of faces that needed work (not the whole DB).
    @discardableResult
    func run(progress: ProgressHandler? = nil) async throws -> (generated: Int, skipped: Int) {
        let candidates = try await fetchCandidates()

        // Filter to only those actually missing a chip. fileExists is sub-ms each
        // and avoids spawning a worker for an already-done face.
        let missing = candidates.filter { !FaceChipStore.chipExists(faceId: $0.faceId) }
        let total = missing.count
        guard total > 0 else { return (0, candidates.count) }

        var generated = 0
        await withTaskGroup(of: Bool.self) { group in
            var inFlight = 0
            var iterator = missing.makeIterator()

            // Prime the pump up to `maxConcurrent` workers.
            while inFlight < Self.maxConcurrent, let next = iterator.next() {
                group.addTask { Self.makeChip(next) }
                inFlight += 1
            }

            // As each completes, kick off the next. Sliding window.
            while let didGenerate = await group.next() {
                inFlight -= 1
                if didGenerate {
                    generated += 1
                    progress?(generated, total)
                }
                if let next = iterator.next() {
                    group.addTask { Self.makeChip(next) }
                    inFlight += 1
                }
            }
        }

        return (generated, candidates.count - generated)
    }

    // MARK: - Internals

    private struct Candidate: Sendable {
        let faceId: String
        let proxyURL: URL
        let sourceURL: URL?
        let bbox: CGRect
    }

    /// Join face_embeddings against photo_assets so each candidate has every input
    /// `FaceChipStore.generateChip` needs without further round-trips per worker.
    private func fetchCandidates() async throws -> [Candidate] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT
                    fe.id AS face_id,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    pa.canonical_name,
                    pa.file_path
                FROM face_embeddings fe
                JOIN photo_assets pa ON pa.id = fe.photo_id
            """)
            return rows.map { row -> Candidate in
                let canonical: String = row["canonical_name"]
                let filePath: String? = row["file_path"]
                let base = (canonical as NSString).deletingPathExtension
                let proxy = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent(base + ".jpg")
                let source: URL? = filePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                let bbox = CGRect(
                    x: row["bbox_x"] as Double,
                    y: row["bbox_y"] as Double,
                    width: row["bbox_width"] as Double,
                    height: row["bbox_height"] as Double
                )
                return Candidate(
                    faceId: row["face_id"],
                    proxyURL: proxy,
                    sourceURL: source,
                    bbox: bbox
                )
            }
        }
    }

    /// Worker body. Runs on a TaskGroup child task — implicit non-isolated context.
    /// Returns true iff a chip was actually written.
    nonisolated private static func makeChip(_ c: Candidate) -> Bool {
        FaceChipStore.generateChip(
            faceId: c.faceId,
            sourceURL: c.sourceURL,
            proxyURL: c.proxyURL,
            bbox: c.bbox
        ) != nil
    }
}
