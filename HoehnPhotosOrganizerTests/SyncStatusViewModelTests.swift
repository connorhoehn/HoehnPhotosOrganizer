// SyncStatusViewModelTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-9: UI reflects sync state per photo — localOnly, syncing, synced, error.
// All tests are stub skips; Wave 2 implementation will drive them RED → GREEN.

import XCTest

final class SyncStatusViewModelTests: XCTestCase {

    /// SYNC-9: Newly ingested photo shows "Local only" sync state.
    /// Verifies: SyncStatusViewModel(photo: newPhoto).status == .localOnly
    func test_syncStatus_localOnly() throws {
        throw XCTSkip("Wave 2+ implementation: new photo → SyncStatusViewModel.status == .localOnly → label \"Local only\"")
    }

    /// SYNC-9: Upload in progress; UI shows "Syncing" with percent complete.
    /// Verifies: SyncStatusViewModel.status == .syncing(progress: 0.42) → label includes progress %.
    func test_syncStatus_syncing() throws {
        throw XCTSkip("Wave 2+ implementation: upload in progress → status == .syncing(progress: X) → UI shows \"Syncing X%\"")
    }

    /// SYNC-9: Upload complete; UI shows "Synced" with timestamp.
    /// Verifies: SyncStatusViewModel.status == .synced(at: Date) → label shows timestamp.
    func test_syncStatus_synced() throws {
        throw XCTSkip("Wave 2+ implementation: upload complete → status == .synced(at: Date) → UI shows \"Synced\" + formatted timestamp")
    }

    /// SYNC-9: Upload failed; UI shows "Error (retry)" with failure reason.
    /// Verifies: SyncStatusViewModel.status == .error(reason: String) → label shows \"Error (retry): {reason}\".
    func test_syncStatus_error() throws {
        throw XCTSkip("Wave 2+ implementation: upload failed → status == .error(reason: \"Network timeout\") → \"Error (retry): Network timeout\"")
    }

    /// SYNC-9: Sync status persisted to DB, survives app restart.
    /// Verifies: syncState column in photo_assets row updated after sync; re-queried value matches.
    func test_syncStatus_persistence() throws {
        throw XCTSkip("Wave 2+ implementation: status == .synced written to DB → app restart → re-queried status == .synced")
    }
}
