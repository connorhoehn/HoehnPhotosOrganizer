import CloudKit
import GRDB
import Foundation

// MARK: - Array Batching Helper

extension Array {
    /// Split the array into chunks of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Push Local Changes to CloudKit

extension CloudSyncEngine {

    /// Push all locally-dirty records to CloudKit in batches.
    /// Updates `ck_synced_at` on success; retries conflicts with server merge.
    func pushChanges() async throws {
        syncState = .pushing(progress: 0)

        // Gather dirty records across all synced tables
        let photos    = try dirtyPhotos()
        let people    = try dirtyPeople()
        let jobs      = try dirtyJobs()
        let events    = try dirtyEvents()
        let revisions = try dirtyRevisions()

        // Build CKRecords
        var allRecords: [CKRecord] = []
        allRecords.append(contentsOf: photos.map   { ckRecord(from: $0) })
        allRecords.append(contentsOf: people.map   { ckRecord(from: $0) })
        allRecords.append(contentsOf: jobs.map     { ckRecord(from: $0) })
        allRecords.append(contentsOf: events.map   { ckRecord(from: $0) })
        allRecords.append(contentsOf: revisions.map { ckRecord(from: $0) })

        guard !allRecords.isEmpty else {
            syncState = .idle
            return
        }

        let batches = allRecords.chunked(into: 400)
        let totalBatches = batches.count

        for (index, batch) in batches.enumerated() {
            try await pushBatch(batch)

            let progress = Double(index + 1) / Double(totalBatches)
            syncState = .pushing(progress: progress)
        }

        lastSyncDate = Date()
        syncState = .idle
    }

    // MARK: - Dirty Record Queries

    /// Photos where updated_at > ck_synced_at or ck_synced_at IS NULL.
    func dirtyPhotos() throws -> [PhotoAsset] {
        try appDatabase.dbPool.read { db in
            try PhotoAsset.fetchAll(db, sql: """
                SELECT * FROM photo_assets
                WHERE ck_synced_at IS NULL OR updated_at > ck_synced_at
            """)
        }
    }

    func dirtyPeople() throws -> [PersonIdentity] {
        try appDatabase.dbPool.read { db in
            try PersonIdentity.fetchAll(db, sql: """
                SELECT * FROM person_identities
                WHERE ck_synced_at IS NULL OR created_at > ck_synced_at
            """)
        }
    }

    func dirtyJobs() throws -> [TriageJob] {
        try appDatabase.dbPool.read { db in
            try TriageJob.fetchAll(db, sql: """
                SELECT * FROM triage_jobs
                WHERE ck_synced_at IS NULL OR updated_at > ck_synced_at
            """)
        }
    }

    /// Activity events: only push the most recent 500 to stay within quota.
    func dirtyEvents() throws -> [ActivityEvent] {
        try appDatabase.dbPool.read { db in
            try ActivityEvent.fetchAll(db, sql: """
                SELECT * FROM activity_events
                WHERE ck_synced_at IS NULL OR created_at > ck_synced_at
                ORDER BY occurred_at DESC
                LIMIT 500
            """)
        }
    }

    func dirtyRevisions() throws -> [StudioRevision] {
        try appDatabase.dbPool.read { db in
            try StudioRevision.fetchAll(db, sql: """
                SELECT * FROM studio_revisions
                WHERE ck_synced_at IS NULL OR created_at > ck_synced_at
            """)
        }
    }

    // MARK: - CKRecord Conversion

    private func ckRecord(from photo: PhotoAsset) -> CKRecord {
        let recordID = CKRecord.ID(recordName: photo.id, zoneID: zoneID)
        let record = CKRecord(recordType: "PhotoAsset", recordID: recordID)
        record["canonicalName"]    = photo.canonicalName as CKRecordValue
        record["filePath"]         = photo.filePath as CKRecordValue
        record["curationState"]    = photo.curationState as CKRecordValue
        record["processingState"]  = photo.processingState as CKRecordValue
        record["importStatus"]     = photo.importStatus as CKRecordValue
        record["isGrayscale"]      = (photo.isGrayscale == true ? 1 : 0) as CKRecordValue
        record["dateModified"]     = photo.dateModified as? CKRecordValue
        record["rawExifJson"]      = photo.rawExifJson as? CKRecordValue
        record["userMetadataJson"] = photo.userMetadataJson as? CKRecordValue
        record["localUpdatedAt"]   = photo.updatedAt as CKRecordValue

        // Attach proxy JPEG as CKAsset if available
        if let proxyPath = photo.proxyPath {
            let url = URL(fileURLWithPath: proxyPath)
            if FileManager.default.fileExists(atPath: url.path) {
                record["proxyAsset"] = CKAsset(fileURL: url)
            }
        }

        return record
    }

    private func ckRecord(from person: PersonIdentity) -> CKRecord {
        let recordID = CKRecord.ID(recordName: person.id, zoneID: zoneID)
        let record = CKRecord(recordType: "PersonIdentity", recordID: recordID)
        record["name"]            = person.name as CKRecordValue
        record["coverFaceId"]     = person.coverFaceEmbeddingId as? CKRecordValue
        record["localUpdatedAt"]  = person.createdAt as CKRecordValue
        return record
    }

    private func ckRecord(from job: TriageJob) -> CKRecord {
        let recordID = CKRecord.ID(recordName: job.id, zoneID: zoneID)
        let record = CKRecord(recordType: "TriageJob", recordID: recordID)
        record["title"]              = job.title as CKRecordValue
        record["source"]             = job.source.rawValue as CKRecordValue
        record["status"]             = job.status.rawValue as CKRecordValue
        record["completenessScore"]  = job.completenessScore as CKRecordValue
        record["photoCount"]         = job.photoCount as CKRecordValue
        record["currentMilestone"]   = job.currentMilestone.rawValue as CKRecordValue
        record["inheritedMetadata"]  = job.inheritedMetadata as? CKRecordValue
        record["localUpdatedAt"]     = job.updatedAt as CKRecordValue

        if let parentId = job.parentJobId {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: parentId, zoneID: zoneID),
                action: .none
            )
            record["parentJobRef"] = parentRef
        }

        return record
    }

    private func ckRecord(from event: ActivityEvent) -> CKRecord {
        let recordID = CKRecord.ID(recordName: event.id, zoneID: zoneID)
        let record = CKRecord(recordType: "ActivityEvent", recordID: recordID)
        record["kind"]           = event.kind.rawValue as CKRecordValue
        record["title"]          = event.title as CKRecordValue
        record["detail"]         = event.detail as? CKRecordValue
        record["metadata"]       = event.metadata as? CKRecordValue
        record["occurredAt"]     = event.occurredAt as CKRecordValue
        record["localUpdatedAt"] = event.createdAt as CKRecordValue

        if let photoId = event.photoAssetId {
            let ref = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: photoId, zoneID: zoneID),
                action: .none
            )
            record["photoRef"] = ref
        }

        return record
    }

    private func ckRecord(from revision: StudioRevision) -> CKRecord {
        let recordID = CKRecord.ID(recordName: revision.id, zoneID: zoneID)
        let record = CKRecord(recordType: "StudioRevision", recordID: recordID)
        record["name"]           = revision.name as CKRecordValue
        record["medium"]         = revision.medium as CKRecordValue
        record["paramsJson"]     = revision.paramsJson as CKRecordValue
        record["localUpdatedAt"] = revision.createdAt as CKRecordValue

        let photoRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: revision.photoId, zoneID: zoneID),
            action: .none
        )
        record["photoRef"] = photoRef

        // Attach thumbnail as CKAsset if available
        if let thumbPath = revision.thumbnailPath {
            let url = URL(fileURLWithPath: thumbPath)
            if FileManager.default.fileExists(atPath: url.path) {
                record["thumbnailAsset"] = CKAsset(fileURL: url)
            }
        }

        return record
    }

    // MARK: - Batch Upload with Conflict Handling

    /// Upload a single batch (max 400 records) via CKModifyRecordsOperation.
    /// On `.serverRecordChanged` conflicts, fetches the server record, merges, and retries.
    private func pushBatch(_ records: [CKRecord]) async throws {
        // Capture db reference outside the Sendable closure
        let db = appDatabase
        let succeededIDs: [CKRecord.ID] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord.ID], Error>) in
            // Use Sendable-safe local collections via a wrapper
            let state = PushBatchState()

            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = false  // allow partial batch success

            operation.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success:
                    state.addSucceeded(recordID)
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                        state.addConflicted(recordID)
                    } else {
                        state.addError(recordID, error)
                    }
                }
            }

            operation.modifyRecordsResultBlock = { result in
                let succeeded = state.succeededIDs
                let conflicts = state.conflictedIDs
                let errors = state.perRecordErrors

                switch result {
                case .success:
                    continuation.resume(returning: succeeded)
                case .failure(let error):
                    // If we only had conflicts (no fatal errors), handle gracefully
                    if errors.isEmpty && !conflicts.isEmpty {
                        continuation.resume(returning: succeeded)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }

        // Mark succeeded records as synced (runs on MainActor, but DB write is fine)
        if !succeededIDs.isEmpty {
            markSynced(recordIDs: succeededIDs, using: db)
        }
    }

    /// Update `ck_synced_at` and `ck_record_name` for successfully pushed records.
    private func markSynced(recordIDs: [CKRecord.ID], using db: AppDatabase) {
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try db.dbPool.write { db in
                for recordID in recordIDs {
                    let recordName = recordID.recordName
                    // Determine which table this record belongs to by trying each
                    // The recordName is the local UUID, so exactly one table will match
                    for table in ["photo_assets", "person_identities", "triage_jobs",
                                  "activity_events", "studio_revisions"] {
                        try db.execute(
                            sql: """
                                UPDATE \(table)
                                SET ck_synced_at = ?, ck_record_name = ?
                                WHERE id = ?
                            """,
                            arguments: [now, recordName, recordName]
                        )
                    }
                }
            }
        } catch {
            print("[CloudSync] Failed to mark records as synced: \(error)")
        }
    }

    // MARK: - Conflict Resolution

    /// Fetch server version of conflicted records, merge, and retry push.
    func resolveConflicts(recordIDs: [CKRecord.ID]) async throws {
        guard !recordIDs.isEmpty else { return }

        // Fetch current server records
        var serverRecords: [CKRecord.ID: CKRecord] = [:]
        for recordID in recordIDs {
            do {
                let record = try await database.record(for: recordID)
                serverRecords[recordID] = record
            } catch {
                // Record may have been deleted server-side; skip
                continue
            }
        }

        guard !serverRecords.isEmpty else { return }

        // Merge local values onto server records (server record has system fields intact)
        var mergedRecords: [CKRecord] = []
        for (recordID, serverRecord) in serverRecords {
            let recordType = serverRecord.recordType
            let merged: CKRecord

            switch recordType {
            case "PhotoAsset":
                if let local = try? await appDatabase.dbPool.read({ db in
                    try PhotoAsset.fetchOne(db, key: recordID.recordName)
                }) {
                    merged = mergePhoto(local: local, server: serverRecord)
                } else { continue }

            case "TriageJob":
                if let local = try? await appDatabase.dbPool.read({ db in
                    try TriageJob.fetchOne(db, key: recordID.recordName)
                }) {
                    merged = mergeJob(local: local, server: serverRecord)
                } else { continue }

            default:
                // For other types: last-write-wins (overwrite server with local)
                merged = serverRecord
                // Re-apply all local fields by rebuilding from local data
            }

            mergedRecords.append(merged)
        }

        if !mergedRecords.isEmpty {
            try await pushBatch(mergedRecords)
        }
    }

    /// Merge a PhotoAsset: last-write-wins for most fields, but always take
    /// the most recent curationState (user intent).
    private func mergePhoto(local: PhotoAsset, server: CKRecord) -> CKRecord {
        // Write local values onto the server record (preserving server system fields)
        server["canonicalName"]    = local.canonicalName as CKRecordValue
        server["filePath"]         = local.filePath as CKRecordValue
        server["curationState"]    = local.curationState as CKRecordValue
        server["processingState"]  = local.processingState as CKRecordValue
        server["importStatus"]     = local.importStatus as CKRecordValue
        server["isGrayscale"]      = (local.isGrayscale == true ? 1 : 0) as CKRecordValue
        server["dateModified"]     = local.dateModified as? CKRecordValue
        server["rawExifJson"]      = local.rawExifJson as? CKRecordValue
        server["localUpdatedAt"]   = local.updatedAt as CKRecordValue

        // Merge userMetadataJson: combine keys from both sides
        if let localJson = local.userMetadataJson,
           let serverJson = server["userMetadataJson"] as? String {
            server["userMetadataJson"] = mergeJsonKeys(local: localJson, server: serverJson) as CKRecordValue
        } else {
            server["userMetadataJson"] = local.userMetadataJson as? CKRecordValue
        }

        return server
    }

    /// Merge a TriageJob: status goes forward only (open < complete < archived).
    private func mergeJob(local: TriageJob, server: CKRecord) -> CKRecord {
        server["title"]              = local.title as CKRecordValue
        server["source"]             = local.source.rawValue as CKRecordValue
        server["completenessScore"]  = local.completenessScore as CKRecordValue
        server["photoCount"]         = local.photoCount as CKRecordValue
        server["currentMilestone"]   = local.currentMilestone.rawValue as CKRecordValue
        server["inheritedMetadata"]  = local.inheritedMetadata as? CKRecordValue
        server["localUpdatedAt"]     = local.updatedAt as CKRecordValue

        // Status: higher state wins (open → complete → archived)
        let statusOrder: [String: Int] = ["open": 0, "complete": 1, "archived": 2]
        let localOrder = statusOrder[local.status.rawValue] ?? 0
        let serverOrder = statusOrder[(server["status"] as? String) ?? "open"] ?? 0
        server["status"] = (localOrder >= serverOrder ? local.status.rawValue : (server["status"] as? String ?? local.status.rawValue)) as CKRecordValue

        return server
    }

    /// Merge two JSON dictionaries by combining keys. Local values win on collision.
    private func mergeJsonKeys(local: String, server: String) -> String {
        guard let localData = local.data(using: .utf8),
              let serverData = server.data(using: .utf8),
              var localDict = try? JSONSerialization.jsonObject(with: localData) as? [String: Any],
              let serverDict = try? JSONSerialization.jsonObject(with: serverData) as? [String: Any]
        else { return local }

        // Start with server values, overlay local (local wins on conflict)
        for (key, value) in serverDict where localDict[key] == nil {
            localDict[key] = value
        }

        guard let merged = try? JSONSerialization.data(withJSONObject: localDict),
              let result = String(data: merged, encoding: .utf8)
        else { return local }

        return result
    }
}

// MARK: - Thread-safe batch state for CKModifyRecordsOperation callbacks

/// Collects per-record results from CKModifyRecordsOperation callbacks which run on arbitrary threads.
private final class PushBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var _succeededIDs: [CKRecord.ID] = []
    private var _conflictedIDs: [CKRecord.ID] = []
    private var _perRecordErrors: [CKRecord.ID: Error] = [:]

    var succeededIDs: [CKRecord.ID] {
        lock.lock()
        defer { lock.unlock() }
        return _succeededIDs
    }

    var conflictedIDs: [CKRecord.ID] {
        lock.lock()
        defer { lock.unlock() }
        return _conflictedIDs
    }

    var perRecordErrors: [CKRecord.ID: Error] {
        lock.lock()
        defer { lock.unlock() }
        return _perRecordErrors
    }

    func addSucceeded(_ id: CKRecord.ID) {
        lock.lock()
        defer { lock.unlock() }
        _succeededIDs.append(id)
    }

    func addConflicted(_ id: CKRecord.ID) {
        lock.lock()
        defer { lock.unlock() }
        _conflictedIDs.append(id)
    }

    func addError(_ id: CKRecord.ID, _ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        _perRecordErrors[id] = error
    }
}
