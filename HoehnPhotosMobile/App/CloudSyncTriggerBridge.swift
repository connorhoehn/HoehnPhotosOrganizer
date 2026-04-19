// CloudSyncTriggerBridge.swift
// HoehnPhotosMobile
//
// iOS counterpart of `MacCloudSyncCoordinator`'s event-trigger plumbing.
// Observes the shared `cloudSync*` Notification.Name values that iOS write
// paths post (curation edits, face / people mutations, …) and kicks
// `CloudSyncEngine.sync()` after a quiet-period debounce so bursts of edits
// collapse into a single CloudKit roundtrip.

import Foundation
import HoehnPhotosCore

/// Bridges in-app edit events to CloudKit sync triggers with debounce.
/// Parallels `MacCloudSyncCoordinator` but runs in the iOS target.
@MainActor
public final class CloudSyncTriggerBridge {

    // MARK: - Dependencies

    private let engine: CloudSyncEngine
    private let debounceSeconds: TimeInterval

    // MARK: - Internal state

    /// The currently scheduled (but not yet fired) debounce task. Cancelled
    /// and replaced whenever a fresh trigger notification arrives.
    private var pendingTrigger: Task<Void, Never>?

    /// The currently running `engine.sync()` task, if any. We coalesce
    /// additional triggers that land while it's executing via the
    /// `resyncRequested` flag below.
    private var runningSync: Task<Void, Never>?

    /// Set to `true` when a trigger fires while a sync is already in flight.
    /// On completion we run exactly one follow-up sync so no late edits are
    /// left stranded locally.
    private var resyncRequested: Bool = false

    /// Tokens for every `NotificationCenter` observer added by `start()`.
    /// Cleared in `stop()`.
    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    public init(engine: CloudSyncEngine, debounceSeconds: TimeInterval = 30) {
        self.engine = engine
        self.debounceSeconds = debounceSeconds
    }

    deinit {
        // Cancel outstanding work without hopping actors — `Task.cancel()` is
        // safe from any context and both handles are plain properties.
        pendingTrigger?.cancel()
        runningSync?.cancel()
    }

    // MARK: - Lifecycle

    /// Start observing edit notifications. Call once on app launch.
    public func start() {
        guard observers.isEmpty else { return }

        // Names observed here match the shared definitions in
        // `HoehnPhotosCore/Sync/SyncNotificationNames.swift`; adding a name
        // there + posting it from a write path is enough to route it through
        // the same debounced trigger.
        let names: [Notification.Name] = [
            .cloudSyncCurationChanged,
            .cloudSyncFacesLabeled,
            .cloudSyncPeopleChanged
        ]

        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `addObserver(forName:object:queue:using:)` with `.main`
                // delivers on the main thread; hop onto the MainActor to
                // mutate bridge state safely.
                Task { @MainActor [weak self] in
                    self?.scheduleSync()
                }
            }
            observers.append(token)
        }
    }

    /// Stop observing. Called on app teardown / sign-out.
    public func stop() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()

        pendingTrigger?.cancel()
        pendingTrigger = nil

        runningSync?.cancel()
        runningSync = nil

        resyncRequested = false
    }

    // MARK: - Debounce

    /// Cancel any pending trigger and schedule a new one `debounceSeconds`
    /// from now. If a sync is already running, flag a follow-up instead so
    /// we don't interrupt the in-flight roundtrip.
    private func scheduleSync() {
        if runningSync != nil {
            resyncRequested = true
            return
        }

        pendingTrigger?.cancel()

        let seconds = debounceSeconds
        pendingTrigger = Task { [weak self] in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.fireSync()
        }
    }

    /// Kick off `engine.sync()` and, when it finishes, run once more if any
    /// triggers arrived mid-flight.
    private func fireSync() {
        pendingTrigger = nil

        // Guard against a re-entrant fire: if something slipped a sync in
        // between scheduling and here, coalesce.
        if runningSync != nil {
            resyncRequested = true
            return
        }

        runningSync = Task { [weak self, engine] in
            await engine.sync()
            await self?.syncDidFinish()
        }
    }

    /// Invoked on the MainActor after a sync returns. Drains any pending
    /// "resync requested" flag by kicking exactly one follow-up cycle.
    private func syncDidFinish() {
        runningSync = nil
        guard resyncRequested else { return }
        resyncRequested = false
        scheduleSync()
    }
}
