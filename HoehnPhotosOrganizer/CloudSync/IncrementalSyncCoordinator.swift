// IncrementalSyncCoordinator.swift
// HoehnPhotosOrganizer
//
// Orchestrates incremental (delta) sync of thread entries to DynamoDB:
//   1. Read lastSyncTimestamp from SyncStateRepository
//   2. Fetch ThreadEntries with syncState == "queued" from ThreadRepository
//   3. Upload to DynamoDB via ThreadSyncClient (25-item batching)
//   4. Mark uploaded entries as "synced" via ThreadRepository
//   5. Update per-photo sync status in SyncStateRepository
//   6. Download remote entries for synced photos and resolve conflicts
//   7. Update lastSyncTimestamp to the server-returned epoch
//
// Architecture notes:
//   - Only entries with syncState == "queued" are uploaded (delta sync).
//   - ThreadEntry.createdAt (ISO8601 String) is converted to Int64 unix epoch
//     when building SyncThreadEntry for upload.
//   - Conflict resolution uses ConflictResolver which wraps LastEditWinsConflictRule.
//   - Photo canonical IDs use photo.canonicalName (not canonicalId).

import Foundation
import Combine

// MARK: - IncrementalSyncCoordinator

actor IncrementalSyncCoordinator {
    /// Publisher that emits sync progress updates.
    /// Observed by SyncStatusViewModel to drive the sync progress indicator.
    nonisolated let progressUpdates = PassthroughSubject<SyncProgressUpdate, Never>()

    private let syncStateRepo: SyncStateRepository
    private let threadSyncClient: ThreadSyncClient
    private let threadRepo: ThreadRepository
    private let conflictResolver: ConflictResolver

    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let iso8601BasicFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    init(
        syncStateRepo: SyncStateRepository,
        threadSyncClient: ThreadSyncClient,
        threadRepo: ThreadRepository,
        conflictResolver: ConflictResolver
    ) {
        self.syncStateRepo = syncStateRepo
        self.threadSyncClient = threadSyncClient
        self.threadRepo = threadRepo
        self.conflictResolver = conflictResolver
    }

    // MARK: - Public API

    /// Perform incremental sync: upload queued entries, download remote changes, resolve conflicts.
    func syncIncremental() async throws {
        // 1. Get last sync cursor
        let lastTs = try await syncStateRepo.getLastSyncTimestamp()

        // 2. Find locally queued thread entries
        let queuedEntries = try await threadRepo.fetchEntriesWithSyncState("queued")

        if queuedEntries.isEmpty {
            // Nothing to upload — still check for remote changes
            progressUpdates.send(SyncProgressUpdate(phase: .downloading, timestamp: Date()))
            try await downloadRemoteChanges(since: lastTs)
            progressUpdates.send(SyncProgressUpdate(phase: .idle, timestamp: Date()))
            return
        }

        // 3. Convert ThreadEntry -> SyncThreadEntry for upload
        let syncEntries = queuedEntries.compactMap { entry -> SyncThreadEntry? in
            let epoch = parseEpoch(from: entry.createdAt)
            let entryType = SyncThreadEntry.EntryType(rawValue: entry.kind) ?? .note
            return SyncThreadEntry(
                threadRootId: entry.threadRootId,
                entryId: entry.id,
                timestamp: epoch,
                type: entryType,
                content: entry.contentJson,
                syncedAt: nil
            )
        }

        // 4. Upload in batches via ThreadSyncClient
        let threadCount = syncEntries.count
        progressUpdates.send(SyncProgressUpdate(phase: .uploadingThreads(completed: 0, total: threadCount), timestamp: Date()))
        let serverTimestamp = try await threadSyncClient.uploadThreadEntries(syncEntries)
        progressUpdates.send(SyncProgressUpdate(phase: .uploadingThreads(completed: threadCount, total: threadCount), timestamp: Date()))

        // 5. Mark uploaded entries as "synced" in local DB
        for entry in queuedEntries {
            try await threadRepo.updateSyncState(entryId: entry.id, syncState: "synced")
        }

        // 6. Update per-photo sync status
        let photoIds = Set(queuedEntries.map(\.threadRootId))
        for photoId in photoIds {
            try await syncStateRepo.updatePhotoSyncStatus(
                canonicalId: photoId,
                status: "synced",
                error: nil
            )
        }

        // 7. Download remote changes and check for conflicts
        progressUpdates.send(SyncProgressUpdate(phase: .downloading, timestamp: Date()))
        try await downloadRemoteChanges(since: lastTs)

        // 8. Advance lastSyncTimestamp to server-returned epoch
        if serverTimestamp > 0 {
            try await syncStateRepo.setLastSyncTimestamp(serverTimestamp)
        }

        progressUpdates.send(SyncProgressUpdate(phase: .idle, timestamp: Date()))
    }

    // MARK: - Private

    /// Download thread entries from remote for photos modified since `timestamp`.
    /// Compares remote entries to local DB; resolves conflicts using ConflictResolver.
    private func downloadRemoteChanges(since timestamp: Int64) async throws {
        let syncedPhotos = try await syncStateRepo.getPhotosModifiedSince(timestamp)

        for photo in syncedPhotos {
            let remoteEntries = try await threadSyncClient.queryThreadHistory(for: photo.canonicalName)
            guard !remoteEntries.isEmpty else { continue }

            let localEntries = try await threadRepo.fetchEntries(forPhoto: photo.canonicalName)

            for remoteEntry in remoteEntries {
                if let localEntry = localEntries.first(where: { $0.id == remoteEntry.entryId }) {
                    // Entry exists locally — compare timestamps to detect conflict
                    let localEpoch = parseEpoch(from: localEntry.createdAt)
                    if localEpoch != remoteEntry.timestamp {
                        let localSync = SyncThreadEntry(
                            threadRootId: localEntry.threadRootId,
                            entryId: localEntry.id,
                            timestamp: localEpoch,
                            type: SyncThreadEntry.EntryType(rawValue: localEntry.kind) ?? .note,
                            content: localEntry.contentJson,
                            syncedAt: nil
                        )
                        let resolution = await conflictResolver.resolve(
                            local: localSync,
                            remote: remoteEntry
                        )
                        // If remote entry wins the conflict, update local record
                        if case .keep(let winner) = resolution,
                           winner.entryId == remoteEntry.entryId {
                            try await threadRepo.updateEntryContent(
                                entryId: remoteEntry.entryId,
                                content: remoteEntry.content,
                                timestamp: remoteEntry.timestamp
                            )
                        }
                    }
                } else {
                    // New remote entry not yet in local DB — insert it
                    try await threadRepo.insertRemoteEntry(remoteEntry)
                }
            }
        }
    }

    /// Convert ISO8601 string from ThreadEntry.createdAt to Unix epoch Int64.
    /// Tries fractional-seconds format first, then basic ISO8601 format.
    private func parseEpoch(from iso: String) -> Int64 {
        if let date = iso8601Formatter.date(from: iso) {
            return Int64(date.timeIntervalSince1970)
        }
        if let date = iso8601BasicFormatter.date(from: iso) {
            return Int64(date.timeIntervalSince1970)
        }
        return 0
    }
}
