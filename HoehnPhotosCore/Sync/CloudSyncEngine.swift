import Foundation
import CloudKit
import Combine
import GRDB

// MARK: - CloudSyncState

public enum CloudSyncState: Equatable, Sendable {
    case idle
    case pushing(progress: Double = 0)
    case pulling(progress: Double = 0)
    case error(String)

    /// Whether the engine is currently performing a sync operation.
    public var isSyncing: Bool {
        switch self {
        case .pushing, .pulling: return true
        default: return false
        }
    }
}

// MARK: - SyncEvent

/// A lightweight record of a completed sync cycle, shown in the mobile sync history UI.
public struct SyncEvent: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let succeeded: Bool
    public let summary: String

    public init(date: Date, succeeded: Bool, summary: String) {
        self.date = date
        self.succeeded = succeeded
        self.summary = summary
    }
}

// MARK: - CloudSyncEngine

/// Orchestrates CloudKit sync between the local GRDB catalog and the private iCloud database.
/// Both macOS and iOS use this engine; the Mac pushes changes, iPhone pulls them,
/// and curation edits flow bidirectionally.
@MainActor
public final class CloudSyncEngine: ObservableObject {

    // MARK: - CloudKit identifiers

    /// The CloudKit container identifier. Must match the `iCloud.<bundle-prefix>` rule and
    /// the entitlements files for both the macOS and iOS targets.
    public static let containerIdentifier = "iCloud.connorhoehn.com.HoehnPhotos"

    // MARK: - CloudKit handles

    public let container: CKContainer
    public let database: CKDatabase
    public let zoneID: CKRecordZone.ID

    // MARK: - Local database

    /// Accessible from CloudSyncPush/Pull extensions.
    let appDatabase: AppDatabase

    // MARK: - Published state

    @Published public var syncState: CloudSyncState = .idle
    @Published public var lastSyncDate: Date?
    @Published public var pendingChangeCount: Int = 0
    @Published public var recentSyncEvents: [SyncEvent] = []

    // MARK: - Auto-sync timer

    private var autoSyncTimer: Timer?

    // MARK: - Init

    public init(appDatabase: AppDatabase) {
        self.container = CKContainer(identifier: CloudSyncEngine.containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: "HoehnPhotosZone", ownerName: CKCurrentUserDefaultName)
        self.appDatabase = appDatabase
    }

    // MARK: - Zone setup

    /// Creates the custom record zone if it does not already exist.
    public func ensureZoneExists() async throws {
        guard Self.isEnabled else {
            print("[CloudSync] ensureZoneExists skipped — CloudKit sync disabled")
            return
        }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            let _ = try await database.save(zone)
            print("[CloudSync] Zone \(zoneID.zoneName) created")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone already exists -- not an error
            print("[CloudSync] Zone \(zoneID.zoneName) already exists")
        }
    }

    // MARK: - Top-level sync orchestration

    /// Run a full sync cycle: ensure zone exists, pull remote changes, push local changes.
    /// Pull and push implementations are in CloudSyncPull.swift and CloudSyncPush.swift.
    public func sync() async {
        guard Self.isEnabled else {
            syncState = .idle
            print("[CloudSync] sync() skipped — CloudKit sync disabled")
            return
        }
        do {
            try await ensureZoneExists()

            try await pullChanges()
            try await pushChanges()

            lastSyncDate = Date()
            syncState = .idle
            recordSyncEvent(succeeded: true, summary: "Sync completed successfully")
            print("[CloudSync] Sync complete at \(lastSyncDate!)")
        } catch {
            syncState = .error(error.localizedDescription)
            recordSyncEvent(succeeded: false, summary: error.localizedDescription)
            print("[CloudSync] Sync failed: \(error)")
        }
    }

    /// Record a sync event for the history UI.
    func recordSyncEvent(succeeded: Bool, summary: String) {
        let event = SyncEvent(date: Date(), succeeded: succeeded, summary: summary)
        recentSyncEvents.insert(event, at: 0)
        // Keep at most 50 events
        if recentSyncEvents.count > 50 {
            recentSyncEvents = Array(recentSyncEvents.prefix(50))
        }
    }

    // MARK: - Auto-sync

    /// Start a repeating timer that triggers `sync()` at the given interval.
    /// Default interval is 5 minutes (300 seconds).
    public func startAutoSync(interval: TimeInterval = 300) {
        guard Self.isEnabled else {
            stopAutoSync()
            print("[CloudSync] startAutoSync skipped — CloudKit sync disabled")
            return
        }
        stopAutoSync()
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sync()
            }
        }
        print("[CloudSync] Auto-sync started with interval \(interval)s")
    }

    /// Stop the periodic sync timer.
    public func stopAutoSync() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }

    // MARK: - Dirty record count (for UI badge)

    /// Counts local records that have changed since their last CloudKit sync.
    /// Uses ck_synced_at vs updated_at comparison.
    public func refreshPendingChangeCount() async {
        guard Self.isEnabled else {
            pendingChangeCount = 0
            return
        }
        do {
            let count = try await appDatabase.dbPool.read { db -> Int in
                let sql = """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE ck_synced_at IS NULL OR updated_at > ck_synced_at
                """
                return try Int.fetchOne(db, sql: sql) ?? 0
            }
            pendingChangeCount = count
        } catch {
            print("[CloudSync] Failed to count pending changes: \(error)")
        }
    }
}

// MARK: - Feature Flag

public extension CloudSyncEngine {
    /// UserDefaults key backing the CloudKit-sync feature flag. Kept as a
    /// public constant so test fixtures and UI bindings can reference the
    /// exact key without hard-coding the string in multiple places.
    static let isEnabledDefaultsKey = "com.hoehn-photos.cloudkit.enabled"

    /// User-toggled master switch for all CloudKit sync activity.
    ///
    /// Defaults to `false` because the app ships without an iCloud developer
    /// entitlement by default; any CloudKit network call would crash or error.
    /// When this returns `false`, every public method on `CloudSyncEngine`
    /// early-returns without making network requests, registering
    /// subscriptions, or creating zones.
    ///
    /// Callers wiring CloudKit-adjacent services (silent-push registration,
    /// trigger bridges, Mac coordinator) should also gate their start-up on
    /// this flag to avoid indirect network activity.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isEnabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: isEnabledDefaultsKey) }
    }
}
