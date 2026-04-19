// MacCloudSyncCoordinator.swift
// HoehnPhotosOrganizer
//
// Mac-specific coordinator that wraps CloudSyncEngine and triggers sync
// after key events (import, curation, job changes, face labeling, renders).
// Debounces sync requests to avoid hammering CloudKit, and runs a periodic
// background timer to catch any changes that slip through event triggers.

import Foundation
import Combine
import HoehnPhotosCore

@MainActor
final class MacCloudSyncCoordinator: ObservableObject {

    // MARK: - Dependencies

    private let cloudSyncEngine: CloudSyncEngine

    // MARK: - Published state

    /// Mirror of the engine's sync state for Mac UI consumption.
    @Published var syncState: CloudSyncState = .idle
    @Published var lastSyncDate: Date?
    @Published var pendingChangeCount: Int = 0
    @Published var autoSyncEnabled: Bool = true

    // MARK: - Debounce / Timer

    /// Minimum interval between triggered syncs (seconds).
    private let debounceInterval: TimeInterval = 30
    private var lastTriggeredSync: Date = .distantPast
    private var periodicSyncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(cloudSyncEngine: CloudSyncEngine) {
        self.cloudSyncEngine = cloudSyncEngine
        observeEngineState()
        observeNotifications()
    }

    deinit {
        periodicSyncTask?.cancel()
    }

    // MARK: - Engine state forwarding

    private func observeEngineState() {
        cloudSyncEngine.$syncState
            .assign(to: &$syncState)
        cloudSyncEngine.$lastSyncDate
            .assign(to: &$lastSyncDate)
        cloudSyncEngine.$pendingChangeCount
            .assign(to: &$pendingChangeCount)
    }

    // MARK: - Notification observers

    /// Wire up to NotificationCenter events the Mac app already posts.
    private func observeNotifications() {
        // Manual sync request from Settings UI
        NotificationCenter.default.publisher(for: .syncNowRequested)
            .sink { [weak self] _ in
                self?.triggerSync(reason: "manual request")
            }
            .store(in: &cancellables)

        // Library cleared — no push needed, but refresh pending count
        NotificationCenter.default.publisher(for: .didClearLibrary)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.cloudSyncEngine.refreshPendingChangeCount()
                }
            }
            .store(in: &cancellables)

        // Photos imported
        NotificationCenter.default.publisher(for: .cloudSyncPhotosImported)
            .compactMap { $0.userInfo?["count"] as? Int }
            .sink { [weak self] count in
                self?.onPhotosImported(count: count)
            }
            .store(in: &cancellables)

        // Curation state changed
        NotificationCenter.default.publisher(for: .cloudSyncCurationChanged)
            .compactMap { $0.userInfo?["photoIds"] as? [String] }
            .sink { [weak self] photoIds in
                self?.onCurationChanged(photoIds: photoIds)
            }
            .store(in: &cancellables)

        // Job status changed (complete/archived)
        NotificationCenter.default.publisher(for: .cloudSyncJobChanged)
            .compactMap { $0.userInfo?["jobId"] as? String }
            .sink { [weak self] jobId in
                self?.onJobStatusChanged(jobId: jobId)
            }
            .store(in: &cancellables)

        // Faces labeled
        NotificationCenter.default.publisher(for: .cloudSyncFacesLabeled)
            .compactMap { $0.userInfo?["count"] as? Int }
            .sink { [weak self] count in
                self?.onFacesLabeled(count: count)
            }
            .store(in: &cancellables)

        // Studio render completed
        NotificationCenter.default.publisher(for: .cloudSyncStudioRendered)
            .compactMap { $0.userInfo?["revisionId"] as? String }
            .sink { [weak self] revisionId in
                self?.onStudioRenderCompleted(revisionId: revisionId)
            }
            .store(in: &cancellables)
    }

    // MARK: - Event trigger methods

    /// Call after a batch import completes to push new photo records.
    func onPhotosImported(count: Int) {
        guard count > 0 else { return }
        print("[MacCloudSync] \(count) photos imported — requesting sync")
        triggerSync(reason: "photos imported (\(count))")
    }

    /// Call when curation state changes (star ratings, picks, rejects).
    func onCurationChanged(photoIds: [String]) {
        guard !photoIds.isEmpty else { return }
        print("[MacCloudSync] Curation changed for \(photoIds.count) photos — requesting sync")
        triggerSync(reason: "curation changed (\(photoIds.count) photos)")
    }

    /// Call when a triage job's status changes.
    func onJobStatusChanged(jobId: String) {
        print("[MacCloudSync] Job \(jobId) status changed — requesting sync")
        triggerSync(reason: "job status changed (\(jobId))")
    }

    /// Call after face labeling to push identity updates.
    func onFacesLabeled(count: Int) {
        guard count > 0 else { return }
        print("[MacCloudSync] \(count) faces labeled — requesting sync")
        triggerSync(reason: "faces labeled (\(count))")
    }

    /// Call when a Studio render finishes to push the new revision.
    func onStudioRenderCompleted(revisionId: String) {
        print("[MacCloudSync] Studio render \(revisionId) completed — requesting sync")
        triggerSync(reason: "studio render completed (\(revisionId))")
    }

    // MARK: - Debounced sync trigger

    /// Triggers a sync unless we are within the debounce window.
    private func triggerSync(reason: String) {
        guard CloudSyncEngine.isEnabled else {
            print("[MacCloudSync] CloudKit sync disabled (feature flag), skipping trigger: \(reason)")
            return
        }
        guard autoSyncEnabled else {
            print("[MacCloudSync] Auto-sync disabled, skipping trigger: \(reason)")
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastTriggeredSync)
        guard elapsed >= debounceInterval else {
            print("[MacCloudSync] Debounced (\(Int(debounceInterval - elapsed))s remaining): \(reason)")
            return
        }

        lastTriggeredSync = now
        print("[MacCloudSync] Triggering sync: \(reason)")
        Task.detached { [engine = cloudSyncEngine] in
            await engine.sync()
        }
    }

    // MARK: - Periodic background sync

    /// Start a repeating background sync that fires every 5 minutes.
    /// Checks for dirty records before pushing to avoid unnecessary network traffic.
    func startPeriodicSync() {
        guard CloudSyncEngine.isEnabled else {
            print("[MacCloudSync] Periodic sync not started — CloudKit sync disabled")
            stopPeriodicSync()
            return
        }
        stopPeriodicSync()
        print("[MacCloudSync] Periodic sync started (5-minute interval)")

        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
                guard !Task.isCancelled else { break }
                guard let self else { break }

                guard self.autoSyncEnabled else { continue }

                // Refresh pending count before deciding to sync
                await self.cloudSyncEngine.refreshPendingChangeCount()
                let pending = self.cloudSyncEngine.pendingChangeCount
                if pending > 0 {
                    print("[MacCloudSync] Periodic sync: \(pending) dirty records, syncing")
                    await self.cloudSyncEngine.sync()
                } else {
                    print("[MacCloudSync] Periodic sync: no dirty records, skipping")
                }
            }
        }
    }

    /// Stop the periodic background sync timer.
    func stopPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
    }
}

// MARK: - Cloud Sync Notification Names
//
// Shared names (cloudSyncPhotosImported / cloudSyncCurationChanged /
// cloudSyncJobChanged / cloudSyncFacesLabeled / cloudSyncStudioRendered) are
// declared in HoehnPhotosCore's `SyncNotificationNames.swift` so the iOS
// target can observe the same `Notification.Name` values.
