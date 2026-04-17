// SyncProgressViewModel.swift
// HoehnPhotosOrganizer
//
// Aggregates sync progress from IncrementalSyncCoordinator, ConflictResolver,
// and GRDB ValueObservation into a single @Published state for toolbar display.

import Foundation
import Combine
import GRDB

@MainActor
class SyncProgressViewModel: ObservableObject {

    // MARK: - Published State

    @Published var overallState: SyncOverallState = .disabled
    @Published var currentPhase: String = ""
    @Published var progressFraction: Double = 0
    @Published var lastSyncTime: Date?
    @Published var lastError: String?
    @Published var queueDepth: Int = 0
    @Published var pendingConflicts: [ConflictResolver.ConflictNotification] = []

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    /// Convenience initializer for disabled/no-sync state.
    init() {
        overallState = .disabled
    }

    /// Production initializer — subscribes to coordinator progress, conflict notifications,
    /// and GRDB ValueObservation for queue depth and last sync timestamp.
    init(
        db: AppDatabase,
        incrementalSync: IncrementalSyncCoordinator,
        conflictResolver: ConflictResolver
    ) {
        overallState = .idle

        // 1. Subscribe to IncrementalSyncCoordinator progress updates
        incrementalSync.progressUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.handleProgressUpdate(update)
            }
            .store(in: &cancellables)

        // 2. Subscribe to ConflictResolver notifications
        conflictResolver.conflictNotifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.pendingConflicts.append(notification)
            }
            .store(in: &cancellables)

        // 3. GRDB ValueObservation: queue depth (thread_entries WHERE sync_state = 'queued')
        let queueObservation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM thread_entries WHERE sync_state = 'queued'
                """) ?? 0
        }

        queueObservation.publisher(in: db.dbPool, scheduling: .immediate)
            .catch { _ in Just(0) }
            .sink { [weak self] count in
                self?.queueDepth = count
            }
            .store(in: &cancellables)

        // 4. GRDB ValueObservation: last sync timestamp from sync_metadata
        let tsObservation = ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: """
                SELECT value, updated_at FROM sync_metadata WHERE key = 'lastSyncTimestamp'
                """)
        }

        tsObservation.publisher(in: db.dbPool, scheduling: .immediate)
            .catch { _ in Just(nil) }
            .sink { [weak self] row in
                guard let row else { return }
                if let epochStr: String = row["value"],
                   let epoch = Int64(epochStr), epoch > 0 {
                    self?.lastSyncTime = Date(timeIntervalSince1970: TimeInterval(epoch))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Conflict Management

    /// Dismiss the first pending conflict notification (used by ConflictBannerView).
    func dismissFirst() {
        guard !pendingConflicts.isEmpty else { return }
        pendingConflicts.removeFirst()
    }

    // MARK: - Helpers

    private func handleProgressUpdate(_ update: SyncProgressUpdate) {
        switch update.phase {
        case .uploadingThreads(let completed, let total):
            overallState = .syncing
            currentPhase = "Uploading threads"
            progressFraction = total > 0 ? Double(completed) / Double(total) : 0

        case .uploadingCatalog(let completed, let total):
            overallState = .syncing
            currentPhase = "Uploading catalog"
            progressFraction = total > 0 ? Double(completed) / Double(total) : 0

        case .uploadingProxies(let completed, let total):
            overallState = .syncing
            currentPhase = "Uploading proxies"
            progressFraction = total > 0 ? Double(completed) / Double(total) : 0

        case .downloading:
            overallState = .syncing
            currentPhase = "Downloading changes"
            progressFraction = -1 // indeterminate

        case .idle:
            overallState = .idle
            currentPhase = ""
            progressFraction = 0
            lastError = nil

        case .error(let message):
            overallState = .error(message)
            currentPhase = ""
            progressFraction = 0
            lastError = message
        }
    }
}
