import Foundation
import GRDB

actor TriageJobRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Job CRUD

    func insert(_ job: TriageJob) async throws {
        try await db.dbPool.write { db in
            var j = job
            try j.insert(db)
        }
    }

    func update(_ job: TriageJob) async throws {
        try await db.dbPool.write { db in
            var j = job
            j.updatedAt = Date()
            try j.update(db)
        }
    }

    func delete(id: String) async throws {
        try await db.dbPool.write { db in
            _ = try TriageJob.deleteOne(db, key: id)
        }
    }

    /// Promotes all staged photos in the job to the library, then marks the job as archived.
    /// This is the terminal "done" action — photos become visible in the main library grid.
    /// Auto-creates a "Before Library Commit" snapshot for any photos that have adjustments.
    func commitJobToLibrary(jobId: String, activityService: ActivityEventService? = nil) async throws {
        let photos = try await fetchPhotos(jobId: jobId)
        let ids = Set(photos.map(\.id))
        // Propagate chat metadata to keeper photos before promoting to library
        try await propagateMetadataToKeeperPhotos(jobId: jobId)
        // Auto-checkpoint: snapshot current adjustments before promoting to library
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        try await snapshotRepo.autoCheckpoint(photoIds: ids, label: "Before Library Commit")
        try await PhotoRepository(db: db).commitToLibrary(ids: ids)
        try await markComplete(jobId: jobId)
        try await markArchived(jobId: jobId)
        // Fire-and-forget activity event — never blocks commit.
        if let activityService {
            let job = try? await fetchById(jobId)
            let title = job?.title ?? "Untitled Job"
            Task { try? await activityService.emitJobCompleted(jobId: jobId, title: title, photoCount: photos.count) }
        }
    }

    /// Permanently deletes all photos belonging to the job (moving source files to Trash),
    /// then deletes the job record itself.
    func cancelAndDeletePhotos(jobId: String) async throws {
        let photos = try await fetchPhotos(jobId: jobId)
        let ids = Set(photos.map(\.id))
        try await PhotoRepository(db: db).permanentlyDelete(ids: ids)
        try await delete(id: jobId)
    }

    func fetchById(_ id: String) async throws -> TriageJob? {
        try await db.dbPool.read { db in
            try TriageJob.fetchOne(db, key: id)
        }
    }

    // MARK: - Queries

    /// All root-level jobs (no parent), ordered newest-first.
    func fetchRootJobs() async throws -> [TriageJob] {
        try await db.dbPool.read { db in
            try TriageJob
                .filter(TriageJob.Columns.parentJobId == nil)
                .order(TriageJob.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Child jobs of a given parent, ordered by creation date.
    func fetchChildJobs(parentId: String) async throws -> [TriageJob] {
        try await db.dbPool.read { db in
            try TriageJob
                .filter(TriageJob.Columns.parentJobId == parentId)
                .order(TriageJob.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// All open jobs (root + children), newest-first.
    func fetchOpenJobs() async throws -> [TriageJob] {
        try await db.dbPool.read { db in
            try TriageJob
                .filter(TriageJob.Columns.status == TriageJobStatus.open.rawValue)
                .order(TriageJob.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Count of open root jobs.
    func openRootJobCount() async throws -> Int {
        try await db.dbPool.read { db in
            try TriageJob
                .filter(TriageJob.Columns.parentJobId == nil)
                .filter(TriageJob.Columns.status == TriageJobStatus.open.rawValue)
                .fetchCount(db)
        }
    }

    // MARK: - Job Photos

    func addPhotos(jobId: String, photoIds: [String]) async throws {
        try await db.dbPool.write { db in
            let existingCount = try TriageJobPhoto
                .filter(TriageJobPhoto.Columns.jobId == jobId)
                .fetchCount(db)

            for (idx, photoId) in photoIds.enumerated() {
                // Skip if already in this job
                let exists = try TriageJobPhoto
                    .filter(TriageJobPhoto.Columns.jobId == jobId)
                    .filter(TriageJobPhoto.Columns.photoId == photoId)
                    .fetchCount(db) > 0
                if exists { continue }

                var entry = TriageJobPhoto(
                    jobId: jobId,
                    photoId: photoId,
                    sortOrder: existingCount + idx,
                    addedAt: Date()
                )
                try entry.insert(db)
            }

            // Update denormalized count
            let newCount = try TriageJobPhoto
                .filter(TriageJobPhoto.Columns.jobId == jobId)
                .fetchCount(db)
            try db.execute(
                sql: "UPDATE triage_jobs SET photo_count = ?, updated_at = ? WHERE id = ?",
                arguments: [newCount, Date(), jobId]
            )
        }
    }

    func removePhotos(jobId: String, photoIds: [String]) async throws {
        try await db.dbPool.write { db in
            for photoId in photoIds {
                try TriageJobPhoto
                    .filter(TriageJobPhoto.Columns.jobId == jobId)
                    .filter(TriageJobPhoto.Columns.photoId == photoId)
                    .deleteAll(db)
            }
            let newCount = try TriageJobPhoto
                .filter(TriageJobPhoto.Columns.jobId == jobId)
                .fetchCount(db)
            try db.execute(
                sql: "UPDATE triage_jobs SET photo_count = ?, updated_at = ? WHERE id = ?",
                arguments: [newCount, Date(), jobId]
            )
        }
    }

    /// Fetch photo IDs belonging to a job, in sort order.
    func fetchPhotoIds(jobId: String) async throws -> [String] {
        try await db.dbPool.read { db in
            try TriageJobPhoto
                .filter(TriageJobPhoto.Columns.jobId == jobId)
                .order(TriageJobPhoto.Columns.sortOrder.asc)
                .fetchAll(db)
                .map(\.photoId)
        }
    }

    /// Fetch full PhotoAsset rows for a job, in sort order.
    func fetchPhotos(jobId: String) async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            try PhotoAsset.fetchAll(db, sql: """
                SELECT pa.* FROM photo_assets pa
                JOIN triage_job_photos tjp ON tjp.photo_id = pa.id
                WHERE tjp.job_id = ?
                ORDER BY tjp.sort_order ASC
            """, arguments: [jobId])
        }
    }

    // MARK: - Status transitions

    func markComplete(jobId: String) async throws {
        try await db.dbPool.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE triage_jobs
                    SET status = ?, completed_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [TriageJobStatus.complete.rawValue, now, now, jobId]
            )
        }
    }

    func markArchived(jobId: String) async throws {
        try await db.dbPool.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE triage_jobs
                    SET status = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [TriageJobStatus.archived.rawValue, now, jobId]
            )
        }
    }

    func reopen(jobId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE triage_jobs
                    SET status = ?, completed_at = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [TriageJobStatus.open.rawValue, Date(), jobId]
            )
        }
    }

    func updateCompleteness(jobId: String, score: Double) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE triage_jobs SET completeness_score = ?, updated_at = ? WHERE id = ?",
                arguments: [score, Date(), jobId]
            )
        }
    }

    // MARK: - Completeness computation

    /// Compute completeness score from the actual photo metadata and persist it.
    ///
    /// Score is built from 4 equal-weight (25%) archive-readiness dimensions:
    ///   1. Curation — all photos have been rated (not needs_review)
    ///   2. People   — all detected faces have a person label
    ///   3. Developed — keeper photos have adjustments applied
    ///   4. Metadata — keeper photos have title or caption in user_metadata_json
    ///
    /// Returns the computed score (0…1).
    @discardableResult
    func computeAndUpdateCompleteness(jobId: String) async throws -> Double {
        let photos = try await fetchPhotos(jobId: jobId)
        guard !photos.isEmpty else {
            try await updateCompleteness(jobId: jobId, score: 0)
            return 0
        }

        let count = Double(photos.count)
        let keeperPhotos = photos.filter { $0.curationState == "keeper" }
        let keeperCount = Double(keeperPhotos.count)

        // Dimension 1: Curation — rated photos / total
        let ratedCount = Double(photos.filter { $0.curationState != "needs_review" }.count)
        let curationScore = ratedCount / count

        // Dimension 2: People — faces with identified person / total faces
        let photoIdList = photos.map { "'\($0.id)'" }.joined(separator: ",")
        let totalFaces: Double = try await db.dbPool.read { d in
            let n = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM face_embeddings WHERE photo_id IN (\(photoIdList))") ?? 0
            return Double(n)
        }
        let identifiedFaces: Double = totalFaces == 0 ? 0 : try await db.dbPool.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT COUNT(DISTINCT fe.id) as cnt
                FROM face_embeddings fe
                JOIN person_identities pi ON pi.id = fe.person_id
                WHERE fe.photo_id IN (\(photoIdList))
                AND pi.name IS NOT NULL AND pi.name != ''
            """)
            return Double(rows.first?["cnt"] as? Int64 ?? 0)
        }
        // If no faces detected, people dimension is fully satisfied
        let peopleScore: Double = totalFaces == 0 ? 1.0 : identifiedFaces / totalFaces

        // Dimension 3: Developed — keepers with adjustments OR a development version / total keepers
        let developedScore: Double
        if keeperCount == 0 {
            developedScore = 1.0  // No keepers yet, not blocking
        } else {
            let keeperIdList = keeperPhotos.map { "'\($0.id)'" }.joined(separator: ",")
            let developedCount: Double = try await db.dbPool.read { d in
                let n = try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE id IN (\(keeperIdList))
                    AND (
                        (adjustments_json IS NOT NULL AND adjustments_json != '' AND adjustments_json != '{}')
                        OR id IN (SELECT DISTINCT photo_id FROM development_versions)
                    )
                """) ?? 0
                return Double(n)
            }
            developedScore = developedCount / keeperCount
        }

        // Dimension 4: Metadata — keepers with title/caption / total keepers
        let metadataScore: Double
        if keeperCount == 0 {
            metadataScore = 1.0  // No keepers yet, not blocking
        } else {
            let keeperIdList = keeperPhotos.map { "'\($0.id)'" }.joined(separator: ",")
            let withMetaCount: Double = try await db.dbPool.read { d in
                let n = try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE id IN (\(keeperIdList))
                    AND user_metadata_json IS NOT NULL
                    AND user_metadata_json != '{}'
                    AND user_metadata_json LIKE '%"title"%'
                """) ?? 0
                return Double(n)
            }
            metadataScore = withMetaCount / keeperCount
        }

        // Equal-weight average across 4 dimensions
        let score = (curationScore  * CompletenessWeights.curation  +
                     peopleScore    * CompletenessWeights.people     +
                     developedScore * CompletenessWeights.developed  +
                     metadataScore  * CompletenessWeights.metadata)

        try await updateCompleteness(jobId: jobId, score: min(1, score))
        return score
    }

    // MARK: - Lightweight task readiness counts

    /// Returns (completedTaskCount, totalTaskCount) for sidebar badge display.
    /// Mirrors the same 4-dimension logic in `JobDetailView.buildTasks()` but
    /// avoids building full `JobTask` objects.
    func computeTaskCounts(jobId: String) async throws -> (completed: Int, total: Int) {
        let photos = try await fetchPhotos(jobId: jobId)
        guard !photos.isEmpty else { return (0, 0) }

        let photoIds = photos.map(\.id)
        let inClause = photoIds.map { "'\($0)'" }.joined(separator: ",")

        // 1. Review & Cull — all photos rated (not needs_review)
        let culled = photos.filter { $0.curationState != "needs_review" }.count
        let reviewDone = culled == photos.count

        // 2. Face identification — all detected faces have a person label
        let totalFaces: Int = try await db.dbPool.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM face_embeddings WHERE photo_id IN (\(inClause))") ?? 0
        }
        let identifiedFaces: Int = totalFaces == 0 ? 0 : try await db.dbPool.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(DISTINCT fe.id) FROM face_embeddings fe
                JOIN person_identities pi ON pi.id = fe.person_id
                WHERE fe.photo_id IN (\(inClause))
                AND pi.name IS NOT NULL AND pi.name != ''
            """) ?? 0
        }
        let hasFaces = totalFaces > 0
        let facesDone = hasFaces && identifiedFaces >= totalFaces

        // 3. Develop — keepers with adjustments OR a development version
        let keeperPhotos = photos.filter { $0.curationState == "keeper" }
        let keeperCount = keeperPhotos.count
        let keeperClause = keeperPhotos.map { "'\($0.id)'" }.joined(separator: ",")
        let developDone: Bool
        if keeperCount == 0 {
            developDone = false
        } else {
            let developed: Int = try await db.dbPool.read { d in
                try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE id IN (\(keeperClause))
                    AND (
                        (adjustments_json IS NOT NULL AND adjustments_json != '' AND adjustments_json != '{}')
                        OR id IN (SELECT DISTINCT photo_id FROM development_versions)
                    )
                """) ?? 0
            }
            developDone = developed >= keeperCount
        }

        // 4. Metadata — keepers with title/caption
        let metadataDone: Bool
        if keeperCount == 0 {
            metadataDone = false
        } else {
            let withoutMeta: Int = try await db.dbPool.read { d in
                try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE id IN (\(keeperClause))
                    AND (
                        user_metadata_json IS NULL
                        OR user_metadata_json = '{}'
                        OR user_metadata_json NOT LIKE '%"title"%'
                    )
                """) ?? 0
            }
            metadataDone = withoutMeta == 0
        }

        // Count total tasks and completed tasks (faces task only appears if faces exist)
        var total = 3  // review, develop, metadata always present
        var completed = 0
        if hasFaces { total += 1 }

        if reviewDone { completed += 1 }
        if hasFaces && facesDone { completed += 1 }
        if developDone { completed += 1 }
        if metadataDone { completed += 1 }

        return (completed, total)
    }

    // MARK: - Sort Order

    /// Persists a new photo ordering for a job. The `photoIds` array defines
    /// the desired sort: index 0 -> sortOrder 0, index 1 -> sortOrder 1, etc.
    func updatePhotoSortOrder(jobId: String, photoIds: [String]) async throws {
        try await db.dbPool.write { db in
            for (index, photoId) in photoIds.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE triage_job_photos
                        SET sort_order = ?
                        WHERE job_id = ? AND photo_id = ?
                    """,
                    arguments: [index, jobId, photoId]
                )
            }
        }
    }

    // MARK: - Metadata propagation

    /// Propagates a job's `inheritedMetadata` to the `user_metadata_json` column
    /// of all keeper photos in the job. Existing per-photo metadata is preserved
    /// via non-destructive merge (job fields fill gaps, never overwrite).
    @discardableResult
    func propagateMetadataToKeeperPhotos(jobId: String) async throws -> Int {
        guard let job = try await fetchById(jobId),
              let metaJson = job.inheritedMetadata,
              !metaJson.isEmpty, metaJson != "{}",
              let metaData = metaJson.data(using: .utf8),
              let jobMeta = try? JSONDecoder().decode(UserMetadata.self, from: metaData)
        else { return 0 }

        let photos = try await fetchPhotos(jobId: jobId)
        let keepers = photos.filter { $0.curationState == "keeper" }
        guard !keepers.isEmpty else { return 0 }

        var updates: [String: String] = [:]
        for photo in keepers {
            let existing = UserMetadata.decode(from: photo.userMetadataJson) ?? UserMetadata()
            let merged = jobMeta.merging(existing)
            if let json = merged.jsonString() {
                updates[photo.id] = json
            }
        }

        guard !updates.isEmpty else { return 0 }
        try await PhotoRepository(db: db).bulkUpdateUserMetadata(updates)
        return updates.count
    }

    // MARK: - Import helper

    /// Create a job from an import batch and link all imported photo IDs.
    func createImportJob(
        title: String,
        photoIds: [String],
        activityService: ActivityEventService? = nil
    ) async throws -> TriageJob {
        let job = TriageJob.newImportJob(title: title, photoCount: photoIds.count)
        try await insert(job)
        try await addPhotos(jobId: job.id, photoIds: photoIds)
        try await computeAndUpdateCompleteness(jobId: job.id)
        // Fire-and-forget activity event — never blocks job creation.
        if let activityService {
            Task { try? await activityService.emitJobCreated(jobId: job.id, title: title, photoCount: photoIds.count) }
        }
        return job
    }
}
