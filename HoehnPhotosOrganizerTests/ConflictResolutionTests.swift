// ConflictResolutionTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-10: Conflict resolution when the same data is edited on two Macs.
// Strategy: last-edit-wins by timestamp, with user notification for visibility.
// All tests are stub skips; Wave 2 implementation will drive them RED → GREEN.

import XCTest

final class ConflictResolutionTests: XCTestCase {

    /// SYNC-10: Mac A edits note at T1, Mac B edits same note at T2 (T2 > T1).
    /// Verifies: ConflictResolver.resolve() keeps Mac B's version (T2 wins).
    func test_conflictResolution_lastEditWins() throws {
        throw XCTSkip("Wave 2+ implementation: T1 local vs T2 remote (T2 > T1) → ConflictResolver keeps remote version (last-edit-wins)")
    }

    /// SYNC-10: User sees "Your other Mac edited this" notification after conflict resolution.
    /// Verifies: ConflictResolver emits ConflictNotification with both versions; user can choose.
    func test_conflictResolution_withNotification() throws {
        throw XCTSkip("Wave 2+ implementation: conflict → ConflictNotification published → user presented with choose-version dialog")
    }

    /// SYNC-10: Mac A edits title field; Mac B edits caption field (different fields).
    /// Verifies: ConflictResolver applies field-level merge when fields are non-overlapping.
    func test_conflictResolution_fieldLevelMerge() throws {
        throw XCTSkip("Wave 2+ implementation: non-overlapping field edits → ConflictResolver merges both fields (title from A + caption from B)")
    }

    /// SYNC-10: Mac A deletes a thread entry (tombstone); Mac B tries to upload an edit to the same entry.
    /// Verifies: ConflictResolver tombstone wins — deleted entry stays deleted, Mac B's edit is discarded.
    func test_conflictResolution_tombstone() throws {
        throw XCTSkip("Wave 2+ implementation: tombstone from Mac A + edit from Mac B → tombstone wins → entry stays deleted")
    }
}
