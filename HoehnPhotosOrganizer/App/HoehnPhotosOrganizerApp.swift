import SwiftUI
import HoehnPhotosCore

@main
struct HoehnPhotosOrganizerApp: App {
    // Local (Mac-only) AppDatabase — owns the DatabasePool and runs the full
    // Mac migration set (including the new v32 `aws_synced_at` columns). All
    // existing Mac features (Studio, PrintLab, ingestion, etc.) read/write via
    // this type and must not be changed.
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

    // AWS sync services — primary sync path for the legacy Thread/Catalog API.
    // Created only when AWS configuration is complete (endpoint, Cognito, bucket).
    // The app launches and functions fully without these (graceful degradation).
    private var awsSyncServices: AWSSyncServices?

    // Cloud sync coordinator — optional, nil when credentials are absent (graceful degradation).
    // Created only when syncEnabled == true AND syncAPIEndpoint is configured.
    // The app launches and functions fully without this coordinator.
    let backgroundSyncCoordinator: BackgroundSyncCoordinator?

    // MARK: - AWS catalog sync (new Cognito-gated path)
    //
    // These mirror the iOS wiring in `HoehnPhotosMobileApp.swift` and use the
    // shared Core `CloudPushCoordinator` / `AWSPullCoordinator` actors. They
    // operate on the SAME underlying GRDB writer as the Mac's local
    // `AppDatabase` (we hand them a Core `AppDatabase` wrapping the same
    // `dbPool`), so schema migrations only run once and both worlds see the
    // same rows.
    //
    // Held as plain `let`s because the underlying types are actors — SwiftUI
    // observation doesn't apply. `start()` is kicked off from a `.task`
    // modifier once the user is authenticated.
    @StateObject private var auth = AuthEnvironment()
    private let cloudSyncAppDatabase: HoehnPhotosCore.AppDatabase
    private let cloudSyncClient: AWSPhotoSyncClient
    private let cloudPushCoordinator: CloudPushCoordinator
    private let cloudPullCoordinator: AWSPullCoordinator

    /// Shared holder so the AWS client's token-provider closure (created in
    /// `init`, before the `AuthEnvironment` StateObject has been materialized
    /// by SwiftUI) can resolve the real environment at request time.
    private let authHolder: AuthEnvironmentHolder

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

        // Start CloudKit periodic sync on launch (when available).
        // Gated on the user-toggled `CloudSyncEngine.isEnabled` flag so that
        // even if the coordinator is wired up in a future build (iCloud
        // entitlement acquired), no network activity starts until the user
        // explicitly opts in from Settings.
        if CloudSyncEngine.isEnabled {
            cloudSyncCoordinator?.startPeriodicSync()
        }

        // ---- AWS catalog sync (Cognito-gated) ----
        //
        // Build a Core `AppDatabase` that shares the Mac's DatabasePool so the
        // Core coordinators see the same rows (and the v32 aws_synced_at
        // columns the Mac migrator just added). We never call .reload() on this
        // Core wrapper — the Mac already owns the file and its lifecycle.
        let coreDb = HoehnPhotosCore.AppDatabase(db.dbPool)
        self.cloudSyncAppDatabase = coreDb

        let holder = AuthEnvironmentHolder()
        self.authHolder = holder

        let config = AWSPhotoSyncConfig(
            apiBaseURL: AuthConfig.apiBaseURL,
            tokenProvider: { [holder] in
                await holder.currentIdToken()
            }
        )
        let client = AWSPhotoSyncClient(config: config)
        self.cloudSyncClient = client

        // No peer fallback on Mac — the Mac is the authoritative catalog
        // source; peer sync on Mac is served by `MacPeerSyncAdvertiser`
        // independently.
        self.cloudPushCoordinator = CloudPushCoordinator(
            appDatabase: coreDb,
            syncClient: client,
            peerFallback: nil
        )
        self.cloudPullCoordinator = AWSPullCoordinator(
            appDatabase: coreDb,
            syncClient: client
        )
    }

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                ContentView()
                    .environment(\.appDatabase, appDatabase)
                    .environmentObject(rollbackEngine)
                    .environmentObject(syncProgressViewModel)
                    .environmentObject(auth)
                    .environment(\.activityEventService, activityEventService)
                    .environment(\.activityEventRepository, activityEventRepo)
                    .environment(\.eventOutboxService, eventOutboxService)
                    .environment(\.eventOutboxProcessor, eventOutboxProcessor)
                    .environment(adjustmentClipboard)
                    .onReceive(NotificationCenter.default.publisher(for: .syncNowRequested)) { _ in
                        guard let coordinator = backgroundSyncCoordinator else { return }
                        Task { try? await coordinator.syncNow() }
                    }
                    .task {
                        // Bind the token resolver before starting the loops so the
                        // first request out of `cloudSyncClient` can resolve a token.
                        await authHolder.bind { [auth] in
                            await auth.currentIdToken()
                        }

                        // Kick the coordinators. When `auth.isAuthenticated`
                        // flips to false the `if/else` re-evaluates, SwiftUI
                        // destroys this branch, and this `.task` is cancelled —
                        // we stop the coordinators in the teardown block below.
                        await cloudPushCoordinator.start()
                        await cloudPullCoordinator.start()
                        // CloudKit gated elsewhere on CloudSyncEngine.isEnabled;
                        // the legacy `cloudSyncCoordinator` path is started from
                        // init() above when the iCloud entitlement is present.

                        // Park until SwiftUI cancels this `.task` (sign-out).
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                            }
                        } catch {
                            // Cancellation — fall through to stop().
                        }

                        await cloudPushCoordinator.stop()
                        await cloudPullCoordinator.stop()
                    }
            } else {
                LoginView()
                    .environmentObject(auth)
                    .task {
                        // Bind the token resolver so that on first sign-in the
                        // AWS client can fetch an id-token the instant the user
                        // lands on the authenticated tree.
                        await authHolder.bind { [auth] in
                            await auth.currentIdToken()
                        }
                    }
            }
        }
        .commands {
            ViewCommands()
        }
    }
}

// MARK: - AuthEnvironment bridge

/// Lightweight actor that exposes the latest `AuthEnvironment.currentIdToken()`
/// to non-MainActor callers (the `AWSPhotoSyncClient` actor). We store a
/// closure instead of a direct `AuthEnvironment` reference so the SwiftUI
/// main-actor type never crosses a non-Sendable boundary.
fileprivate actor AuthEnvironmentHolder {
    private var resolver: (@Sendable () async -> String?)?

    func bind(_ resolver: @escaping @Sendable () async -> String?) {
        self.resolver = resolver
    }

    func currentIdToken() async -> String? {
        guard let resolver else { return nil }
        return await resolver()
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
