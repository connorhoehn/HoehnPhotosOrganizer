import Foundation
import GRDB
import os.log

actor BackgroundJobCoordinator {
    private let db: AppDatabase
    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "BackgroundJobCoordinator")

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Launch guard

    /// Call once on app launch. Resets any status=running rows to status=interrupted
    /// so rehydration can create fresh Task instances from the cursor.
    func resetInterruptedJobs() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE background_jobs
                SET status = 'interrupted', updated_at = ?
                WHERE status = 'running'
            """, arguments: [now])
        }
        logger.info("resetInterruptedJobs: all running jobs marked interrupted")
    }

    // MARK: - Job lifecycle

    /// Returns an existing running or interrupted job of this type, or creates a new one.
    func startOrResume(type: JobType, driveId: String? = nil) async throws -> BackgroundJob {
        if let existing = try await fetchRunningOrInterruptedJob(type: type) {
            logger.info("startOrResume: resuming existing job \(existing.id) type=\(type.rawValue) status=\(existing.status)")
            return existing
        }
        let job = BackgroundJob.new(type: type, driveId: driveId)
        try await db.dbPool.write { db in
            try job.insert(db)
        }
        logger.info("startOrResume: created new job \(job.id) type=\(type.rawValue)")
        return job
    }

    /// Persists the current cursor so the job can be resumed from this point after a restart.
    func checkpoint(_ job: BackgroundJob, cursorJson: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE background_jobs
                SET cursor_json = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [cursorJson, now, job.id])
        }
    }

    /// Marks the job as completed.
    func complete(jobId: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE background_jobs SET status = 'completed', updated_at = ?
                WHERE id = ?
            """, arguments: [now, jobId])
        }
        logger.info("complete: job \(jobId) marked completed")
    }

    /// Marks the job as failed with an error message.
    func fail(jobId: String, message: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE background_jobs SET status = 'failed', error_message = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [message, now, jobId])
        }
    }

    // MARK: - Queries

    func fetchRunningOrInterruptedJob(type: JobType) async throws -> BackgroundJob? {
        try await db.dbPool.read { db in
            try BackgroundJob
                .filter(Column("type") == type.rawValue)
                .filter(sql: "status IN ('running', 'interrupted')")
                .fetchOne(db)
        }
    }

    func fetchAllActive() async throws -> [BackgroundJob] {
        try await db.dbPool.read { db in
            try BackgroundJob
                .filter(sql: "status IN ('pending', 'running', 'interrupted')")
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }
}
