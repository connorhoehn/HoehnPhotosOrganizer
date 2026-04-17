// ConflictResolver.swift
// HoehnPhotosOrganizer
//
// Wraps LastEditWinsConflictRule (from SyncModels.swift) with a Combine publisher
// so the UI can display "edited on another Mac" notifications without blocking sync.
//
// Architecture notes:
//   - conflictNotifications is nonisolated so SwiftUI views can subscribe without
//     needing to hop onto the actor.
//   - Conflict notification is fire-and-forget (send does not throw or await).
//   - The actor owns the LastEditWinsConflictRule instance to ensure thread safety;
//     the rule itself is a Sendable struct so isolation is not strictly required.

import Foundation
import Combine

// MARK: - ConflictResolver

actor ConflictResolver {

    // MARK: - Conflict Notification

    /// Publisher that emits when a conflict is resolved.
    /// Observed by LibraryViewModel to show "edited on another Mac" alerts.
    nonisolated let conflictNotifications = PassthroughSubject<ConflictNotification, Never>()

    struct ConflictNotification: Sendable {
        /// Photo canonical ID of the thread that had a conflict.
        let photoId: String
        /// Unix epoch seconds of the local entry timestamp at conflict time.
        let localTimestamp: Int64
        /// Unix epoch seconds of the remote entry timestamp at conflict time.
        let remoteTimestamp: Int64
        /// The resolution chosen by LastEditWinsConflictRule.
        let resolution: ConflictResolution
    }

    // MARK: - Private

    private nonisolated(unsafe) let rule = LastEditWinsConflictRule()

    // MARK: - Public API

    /// Resolve a conflict between a local and remote thread entry.
    ///
    /// Uses LastEditWinsConflictRule: the entry with the later timestamp wins;
    /// ties are broken by lexicographic comparison of entryId.
    ///
    /// - Returns: ConflictResolution indicating which entry to keep.
    func resolve(local: SyncThreadEntry, remote: SyncThreadEntry) -> ConflictResolution {
        let resolution = rule.applyRule(local: local, remote: remote)

        let notification = ConflictNotification(
            photoId: local.threadRootId,
            localTimestamp: local.timestamp,
            remoteTimestamp: remote.timestamp,
            resolution: resolution
        )
        conflictNotifications.send(notification)

        return resolution
    }
}
