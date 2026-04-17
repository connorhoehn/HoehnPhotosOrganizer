// SyncStatusViewModel.swift
// HoehnPhotosOrganizer
//
// Per-photo sync state observer. Uses GRDB ValueObservation to live-track
// sync_status for a given photo's canonical_name.
//
// Usage: create in a detail/inspector view, call observeSyncStatus(for:) with
// the photo's canonicalName, then read syncStatus/@Published for display.

import Foundation
import GRDB
import Combine

@MainActor
class SyncStatusViewModel: ObservableObject {
    @Published var syncStatus: SyncStatus = .localOnly
    @Published var lastSyncTime: Date?

    private var cancellable: AnyCancellable?
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func observeSyncStatus(for canonicalId: String) {
        // Use ValueObservation to live-observe sync_status for this photo
        let observation = ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: """
                SELECT sync_status, last_synced_at
                FROM photo_assets
                WHERE canonical_name = ?
                """, arguments: [canonicalId])
        }

        cancellable = observation.publisher(in: db.dbPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] row in
                    guard let self, let row else { return }
                    let statusString: String = row["sync_status"]
                    // Decode SyncStatus from JSON string stored in column
                    if let data = statusString.data(using: .utf8),
                       let status = try? JSONDecoder().decode(SyncStatus.self, from: data) {
                        self.syncStatus = status
                    } else {
                        // Fallback for simple string values (e.g. "localOnly" from migration default)
                        self.syncStatus = .localOnly
                    }
                    if let isoString: String = row["last_synced_at"] {
                        self.lastSyncTime = ISO8601DateFormatter().date(from: isoString)
                    }
                }
            )
    }

    func stopObserving() {
        cancellable = nil
    }
}
