import CloudKit
import GRDB
import Foundation
import os.log

private let logger = Logger(subsystem: "com.connorhoehn.HoehnPhotos", category: "CloudSyncPull")

// MARK: - Change Token Persistence

extension CloudSyncEngine {

    /// The UserDefaults key for the persisted CKServerChangeToken.
    private static let changeTokenKey = "ck_serverChangeToken"

    /// Load the saved CKServerChangeToken from UserDefaults.
    var savedChangeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.changeTokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: Self.changeTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.changeTokenKey)
            }
        }
    }
}

// MARK: - Pull Remote Changes

extension CloudSyncEngine {

    /// Fetch remote changes from CloudKit and apply them to the local GRDB database.
    /// Uses incremental fetch via CKServerChangeToken when available; otherwise fetches everything.
    func pullChanges() async throws {
        syncState = .pulling(progress: 0.0)
        logger.info("Pull started (hasToken: \(self.savedChangeToken != nil))")

        let (changed, deleted, newToken) = try await fetchRemoteChanges()
        logger.info("Fetched \(changed.count) changed, \(deleted.count) deleted records")

        syncState = .pulling(progress: 0.3)

        try await applyChanges(changed: changed, deleted: deleted)

        syncState = .pulling(progress: 0.9)

        // Persist the new token only after successful apply
        if let newToken {
            savedChangeToken = newToken
            logger.info("Saved new change token")
        }

        lastSyncDate = Date()
        syncState = .idle
        logger.info("Pull complete")
    }

    // MARK: - Fetch via CKFetchRecordZoneChangesOperation

    /// Returns (changedRecords, deletedRecordIDs, latestToken).
    private func fetchRemoteChanges() async throws -> ([CKRecord], [(CKRecord.ID, CKRecord.RecordType)], CKServerChangeToken?) {
        let currentToken = savedChangeToken
        let currentZoneID = zoneID
        let currentDatabase = database

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let state = PullBatchState(initialToken: currentToken)

                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                    previousServerChangeToken: currentToken
                )

                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [currentZoneID],
                    configurationsByRecordZoneID: [currentZoneID: config]
                )
                operation.qualityOfService = .userInitiated

                operation.recordWasChangedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        state.addChanged(record)
                    case .failure(let error):
                        logger.error("recordWasChanged error: \(error.localizedDescription)")
                    }
                }

                operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                    state.addDeleted(recordID, recordType)
                }

                operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                    if let token { state.updateToken(token) }
                }

                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: state.snapshot())
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                currentDatabase.add(operation)
            }
        } catch {
            // If token is expired/invalid, clear it so next pull does a full fetch
            if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                logger.warning("Change token expired — clearing for full re-fetch")
                savedChangeToken = nil
            }
            throw error
        }
    }

    // MARK: - Apply Changes to Local GRDB

    private func applyChanges(changed: [CKRecord], deleted: [(CKRecord.ID, CKRecord.RecordType)]) async throws {
        let total = changed.count + deleted.count
        guard total > 0 else { return }

        let nowISO = ISO8601DateFormatter().string(from: Date())
        var processed = 0

        // Batch in groups of 200 to avoid holding a write lock too long
        let batchSize = 200

        // --- Upserts ---
        for batch in changed.chunked(into: batchSize) {
            try await appDatabase.dbPool.write { [self] db in
                for record in batch {
                    try self.upsertRecord(record, in: db, syncedAt: nowISO)
                }
            }
            processed += batch.count
            let progress = 0.3 + 0.6 * Double(processed) / Double(total)
            syncState = .pulling(progress: min(progress, 0.9))
        }

        // --- Proxy asset downloads (queued, non-blocking) ---
        let assetRecords = changed.filter { $0.recordType == "PhotoAsset" && $0["proxyAsset"] is CKAsset }
        if !assetRecords.isEmpty {
            Task.detached(priority: .background) { [weak self] in
                await self?.downloadProxyAssets(from: assetRecords)
            }
        }

        // --- Deletes ---
        for batch in deleted.chunked(into: batchSize) {
            try await appDatabase.dbPool.write { [self] db in
                for (recordID, recordType) in batch {
                    try self.deleteLocalRecord(recordID: recordID, recordType: recordType, in: db)
                }
            }
            processed += batch.count
            let progress = 0.3 + 0.6 * Double(processed) / Double(total)
            syncState = .pulling(progress: min(progress, 0.9))
        }
    }

    /// Convert a CKRecord to the appropriate GRDB model and INSERT OR REPLACE.
    private nonisolated func upsertRecord(_ record: CKRecord, in db: Database, syncedAt: String) throws {
        let recordName = record.recordID.recordName

        switch record.recordType {
        case "PhotoAsset":
            try db.execute(sql: """
                INSERT OR REPLACE INTO photo_assets
                    (id, canonical_name, role, file_path, file_size, date_modified,
                     raw_exif_json, user_metadata_json, processing_state, curation_state,
                     sync_state, is_grayscale, import_status, created_at, updated_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    record["canonicalName"] as? String ?? "",
                    record["role"] as? String ?? "original",
                    record["filePath"] as? String ?? "",
                    record["fileSize"] as? Int64 ?? 0,
                    record["dateModified"] as? String,
                    record["rawExifJson"] as? String,
                    record["userMetadataJson"] as? String,
                    record["processingState"] as? String ?? "indexed",
                    record["curationState"] as? String ?? "needsReview",
                    "synced",
                    record["isGrayscale"] as? Int64 ?? 0,
                    record["importStatus"] as? String ?? "library",
                    record["createdAt"] as? String ?? syncedAt,
                    record["localUpdatedAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "PersonIdentity":
            try db.execute(sql: """
                INSERT OR REPLACE INTO person_identities
                    (id, name, cover_face_embedding_id, created_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    record["name"] as? String ?? "",
                    record["coverFaceId"] as? String,
                    record["createdAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "FaceEmbedding":
            let photoRef = record["photoRef"] as? CKRecord.Reference
            let personRef = record["personRef"] as? CKRecord.Reference
            try db.execute(sql: """
                INSERT OR REPLACE INTO face_embeddings
                    (id, photo_id, face_index,
                     bbox_x, bbox_y, bbox_width, bbox_height,
                     labeled_by, needs_review, person_id, created_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    photoRef?.recordID.recordName ?? "",
                    record["faceIndex"] as? Int64 ?? 0,
                    record["bboxX"] as? Double ?? 0,
                    record["bboxY"] as? Double ?? 0,
                    record["bboxWidth"] as? Double ?? 0,
                    record["bboxHeight"] as? Double ?? 0,
                    record["labeledBy"] as? String,
                    record["needsReview"] as? Int64 ?? 0,
                    personRef?.recordID.recordName,
                    record["createdAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "TriageJob":
            let parentRef = record["parentJobRef"] as? CKRecord.Reference
            try db.execute(sql: """
                INSERT OR REPLACE INTO triage_jobs
                    (id, parent_job_id, title, source, status,
                     inherited_metadata, completeness_score, photo_count,
                     current_milestone, created_at, updated_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    parentRef?.recordID.recordName,
                    record["title"] as? String ?? "",
                    record["source"] as? String ?? "manual",
                    record["status"] as? String ?? "open",
                    record["inheritedMetadata"] as? String,
                    record["completenessScore"] as? Double ?? 0.0,
                    record["photoCount"] as? Int64 ?? 0,
                    record["currentMilestone"] as? String ?? "triage",
                    record["createdAt"] as? String ?? syncedAt,
                    record["localUpdatedAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "TriageJobPhoto":
            let jobRef = record["jobRef"] as? CKRecord.Reference
            let photoRef = record["photoRef"] as? CKRecord.Reference
            try db.execute(sql: """
                INSERT OR REPLACE INTO triage_job_photos
                    (job_id, photo_id, sort_order, added_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    jobRef?.recordID.recordName ?? "",
                    photoRef?.recordID.recordName ?? "",
                    record["sortOrder"] as? Int64 ?? 0,
                    record["localUpdatedAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "ActivityEvent":
            let photoRef = record["photoRef"] as? CKRecord.Reference
            try db.execute(sql: """
                INSERT OR REPLACE INTO activity_events
                    (id, kind, photo_asset_id, title, detail, metadata,
                     occurred_at, created_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    record["kind"] as? String ?? "note",
                    photoRef?.recordID.recordName,
                    record["title"] as? String ?? "",
                    record["detail"] as? String,
                    record["metadata"] as? String,
                    record["occurredAt"] as? String ?? syncedAt,
                    record["createdAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        case "StudioRevision":
            let photoRef = record["photoRef"] as? CKRecord.Reference
            try db.execute(sql: """
                INSERT OR REPLACE INTO studio_revisions
                    (id, photo_id, name, medium, params_json, created_at,
                     ck_record_name, ck_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordName,
                    photoRef?.recordID.recordName ?? "",
                    record["name"] as? String ?? "",
                    record["medium"] as? String ?? "Oil Painting",
                    record["paramsJson"] as? String ?? "{}",
                    record["createdAt"] as? String ?? syncedAt,
                    recordName,
                    syncedAt
                ])

        default:
            logger.warning("Unknown record type during pull: \(record.recordType)")
        }
    }

    /// Delete a local record matching the CloudKit deletion.
    private nonisolated func deleteLocalRecord(recordID: CKRecord.ID, recordType: CKRecord.RecordType, in db: Database) throws {
        let recordName = recordID.recordName

        switch recordType {
        case "PhotoAsset":
            try db.execute(sql: "DELETE FROM photo_assets WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        case "PersonIdentity":
            try db.execute(sql: "DELETE FROM person_identities WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        case "FaceEmbedding":
            try db.execute(sql: "DELETE FROM face_embeddings WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        case "TriageJob":
            try db.execute(sql: "DELETE FROM triage_jobs WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        case "TriageJobPhoto":
            try db.execute(sql: "DELETE FROM triage_job_photos WHERE ck_record_name = ?",
                           arguments: [recordName])
        case "ActivityEvent":
            try db.execute(sql: "DELETE FROM activity_events WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        case "StudioRevision":
            try db.execute(sql: "DELETE FROM studio_revisions WHERE id = ? OR ck_record_name = ?",
                           arguments: [recordName, recordName])
        default:
            logger.warning("Unknown record type for delete: \(recordType)")
        }
    }

    // MARK: - Proxy Asset Downloads (Background)

    /// Copy proxy JPEG files from CKAsset temp URLs to the local proxy directory.
    /// Runs on a background task — does not block the pull flow.
    private func downloadProxyAssets(from records: [CKRecord]) async {
        let fm = FileManager.default
        let proxyDir = Self.proxyDirectory

        // Ensure proxy directory exists
        try? fm.createDirectory(at: proxyDir, withIntermediateDirectories: true)

        for record in records {
            guard let asset = record["proxyAsset"] as? CKAsset,
                  let tempURL = asset.fileURL,
                  let canonicalName = record["canonicalName"] as? String else { continue }

            let destURL = proxyDir.appendingPathComponent("\(canonicalName).jpg")

            // Skip if already exists (avoid redundant copies)
            guard !fm.fileExists(atPath: destURL.path) else { continue }

            do {
                try fm.copyItem(at: tempURL, to: destURL)
                logger.debug("Cached proxy: \(canonicalName)")
            } catch {
                logger.error("Failed to cache proxy \(canonicalName): \(error.localizedDescription)")
            }
        }
    }

    /// The local directory where proxy JPEGs are stored.
    static var proxyDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("HoehnPhotos/proxies", isDirectory: true)
    }
}

// MARK: - Push Notification Subscription

extension CloudSyncEngine {

    /// Subscribe to remote changes via silent push notification.
    /// Only creates the subscription once — checks for existing first.
    func subscribeToChanges() async throws {
        guard Self.isEnabled else {
            logger.info("subscribeToChanges skipped — CloudKit sync disabled")
            return
        }
        let subscriptionID = "HoehnPhotosZone-changes"

        // Check if already subscribed
        do {
            _ = try await database.subscription(for: subscriptionID)
            logger.info("Push subscription already exists")
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Subscription doesn't exist yet — create it below
        } catch {
            // For other errors (network etc.), still try to create
            logger.warning("Could not check existing subscription: \(error.localizedDescription)")
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )

        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true  // silent push → triggers background fetch
        subscription.notificationInfo = info

        _ = try await database.save(subscription)
        logger.info("Created push subscription for HoehnPhotosZone")
    }
}

// Note: Array.chunked(into:) is defined in CloudSyncPush.swift

// MARK: - Thread-safe batch state for CKFetchRecordZoneChanges callbacks

/// Collects records from CKFetchRecordZoneChangesOperation callbacks which run on arbitrary threads.
private final class PullBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var changedRecords: [CKRecord] = []
    private var deletedIDs: [(CKRecord.ID, CKRecord.RecordType)] = []
    private var latestToken: CKServerChangeToken?

    init(initialToken: CKServerChangeToken?) {
        self.latestToken = initialToken
    }

    func addChanged(_ record: CKRecord) {
        lock.lock()
        defer { lock.unlock() }
        changedRecords.append(record)
    }

    func addDeleted(_ recordID: CKRecord.ID, _ recordType: CKRecord.RecordType) {
        lock.lock()
        defer { lock.unlock() }
        deletedIDs.append((recordID, recordType))
    }

    func updateToken(_ token: CKServerChangeToken) {
        lock.lock()
        defer { lock.unlock() }
        latestToken = token
    }

    func snapshot() -> ([CKRecord], [(CKRecord.ID, CKRecord.RecordType)], CKServerChangeToken?) {
        lock.lock()
        defer { lock.unlock() }
        return (changedRecords, deletedIDs, latestToken)
    }
}
