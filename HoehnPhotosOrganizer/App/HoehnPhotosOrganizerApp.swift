import SwiftUI
import HoehnPhotosCore

@main
struct HoehnPhotosOrganizerApp: App {
    let appDatabase: AppDatabase = {
        do { return try AppDatabase.makeShared() }
        catch { fatalError("Failed to open database: \(error)") }
    }()

    // Shared activity stack — injected into environment and reused by RollbackEngine.
    let activityEventRepo: ActivityEventRepository
    let activityEventService: ActivityEventService
    let eventOutboxService: EventOutboxService
    let eventOutboxProcessor: EventOutboxProcessor

    @StateObject private var rollbackEngine: RollbackEngine
    @StateObject private var syncProgressViewModel: SyncProgressViewModel
    let adjustmentClipboard = AdjustmentClipboard()

    // CloudKit sync engine and Mac-specific coordinator (legacy — kept as fallback).
    // Optional — nil when iCloud entitlement is unavailable (e.g. personal dev team).
    private var cloudSyncEngine: CloudSyncEngine?
    private var cloudSyncCoordinator: MacCloudSyncCoordinator?

    // AWS sync services — primary sync path.
    // Created only when AWS configuration is complete (endpoint, Cognito, bucket).
    // The app launches and functions fully without these (graceful degradation).
    private var awsSyncServices: AWSSyncServices?

    // Cloud sync coordinator — optional, nil when credentials are absent (graceful degradation).
    // Created only when syncEnabled == true AND syncAPIEndpoint is configured.
    // The app launches and functions fully without this coordinator.
    let backgroundSyncCoordinator: BackgroundSyncCoordinator?

    init() {
        let db: AppDatabase
        do { db = try AppDatabase.makeShared() }
        catch { fatalError("Failed to open database: \(error)") }

        let repo = ActivityEventRepository(db: db)
        let service = ActivityEventService(repo: repo)
        let outbox = EventOutboxService(db: db)
        let processor = EventOutboxProcessor(outboxService: outbox, activityService: service)

        activityEventRepo = repo
        activityEventService = service
        eventOutboxService = outbox
        eventOutboxProcessor = processor

        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        _rollbackEngine = StateObject(wrappedValue: RollbackEngine(snapshotRepo: snapshotRepo, activityService: service))

        // CloudKit sync engine + Mac coordinator
        // Skipped until iCloud entitlement is available (requires paid Apple Developer account).
        // CKContainer(identifier:) crashes without the entitlement.
        cloudSyncEngine = nil
        cloudSyncCoordinator = nil

        // Initialize API usage logger for cost tracking
        Task { await APIUsageLogger.shared.configure(db: db) }

        // Wire AWS sync services when configuration is complete.
        // Uses AWSSyncServiceFactory to build the full authenticated client graph.
        // Graceful degradation: if config is incomplete, services are nil and sync is disabled.
        let factory = AWSSyncServiceFactory(db: db)
        if let services = factory.build() {
            awsSyncServices = services
            backgroundSyncCoordinator = services.backgroundSync
            _syncProgressViewModel = StateObject(wrappedValue: services.syncProgressViewModel)
            Task { await services.backgroundSync.startPeriodicSync() }
        } else {
            awsSyncServices = nil
            backgroundSyncCoordinator = nil
            _syncProgressViewModel = StateObject(wrappedValue: SyncProgressViewModel())
        }

        // Start CloudKit periodic sync on launch (when available)
        cloudSyncCoordinator?.startPeriodicSync()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appDatabase, appDatabase)
                .environmentObject(rollbackEngine)
                .environmentObject(syncProgressViewModel)
                .environment(\.activityEventService, activityEventService)
                .environment(\.activityEventRepository, activityEventRepo)
                .environment(\.eventOutboxService, eventOutboxService)
                .environment(\.eventOutboxProcessor, eventOutboxProcessor)
                .environment(adjustmentClipboard)
                .onReceive(NotificationCenter.default.publisher(for: .syncNowRequested)) { _ in
                    guard let coordinator = backgroundSyncCoordinator else { return }
                    Task { try? await coordinator.syncNow() }
                }
        }
        .commands {
            ViewCommands()
        }
    }
}

// MARK: - ViewCommands

private struct ViewCommands: Commands {
    @AppStorage("layout.inspectorVisible") var inspectorVisible = false

    var body: some Commands {
        CommandMenu("View") {
            Button(inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Jump to Adjustments") {
                UserDefaults.standard.set(true, forKey: "inspector.panel.adjustments")
                inspectorVisible = true
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Button("Jump to Editorial Feedback") {
                UserDefaults.standard.set(true, forKey: "inspector.panel.editorial")
                inspectorVisible = true
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Divider()

            Button("Reset Panel Layout") {
                let d = UserDefaults.standard
                d.set(true,  forKey: "inspector.panel.adjustments")
                d.set(true,  forKey: "inspector.panel.editorial")
                d.set(true,  forKey: "inspector.panel.workflow")
                d.set(false, forKey: "inspector.panel.pipelines")
                d.set(false, forKey: "inspector.panel.lineage")
                d.set(false, forKey: "inspector.panel.asset")
                d.set(false, forKey: "inspector.panel.metadata")
                d.set(false, forKey: "inspector.panel.dates")
                d.set(false, forKey: "inspector.panel.similarity")
                d.set(false, forKey: "inspector.panel.generative")
                d.set(false, forKey: "inspector.panel.notes")
            }
        }
    }
}
