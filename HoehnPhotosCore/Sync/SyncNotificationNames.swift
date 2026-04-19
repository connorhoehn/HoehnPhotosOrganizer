// SyncNotificationNames.swift
// HoehnPhotosCore
//
// Shared `Notification.Name` values that in-app write paths post when they
// touch data that should eventually be replicated through CloudKit. Both the
// Mac coordinator (`MacCloudSyncCoordinator`) and the iOS bridge
// (`CloudSyncTriggerBridge`) observe these names to kick debounced syncs.
//
// Living in HoehnPhotosCore so both the macOS and iOS targets see the exact
// same `Notification.Name` values — posts from Mac-only code stay usable from
// iOS write paths without string-literal drift.

import Foundation

public extension Notification.Name {
    /// Posted after a batch import finishes. `userInfo["count"]` carries the
    /// number of newly imported photos.
    static let cloudSyncPhotosImported = Notification.Name("cloudSyncPhotosImported")

    /// Posted whenever curation state (keeper / archive / needs-review /
    /// rejected) is written for one or more photos. `userInfo["photoIds"]`
    /// carries the affected ids when available.
    static let cloudSyncCurationChanged = Notification.Name("cloudSyncCurationChanged")

    /// Posted when a triage job transitions status (complete / archived / …).
    /// `userInfo["jobId"]` carries the affected job id.
    static let cloudSyncJobChanged = Notification.Name("cloudSyncJobChanged")

    /// Posted after face labeling writes identities to one or more faces.
    /// `userInfo["count"]` carries the number of faces touched.
    static let cloudSyncFacesLabeled = Notification.Name("cloudSyncFacesLabeled")

    /// Posted when a Studio render finishes. `userInfo["revisionId"]` carries
    /// the revision identifier that just landed.
    static let cloudSyncStudioRendered = Notification.Name("cloudSyncStudioRendered")

    /// Posted after rename / merge / delete operations against a person
    /// cluster. iOS's face-review flow is the primary emitter today.
    static let cloudSyncPeopleChanged = Notification.Name("cloudSyncPeopleChanged")
}
