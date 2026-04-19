import SwiftUI
import HoehnPhotosCore

@main
struct HoehnPhotosMobileApp: App {

    let appDatabase: AppDatabase
    @StateObject private var syncService = PeerSyncService()
    @StateObject private var cloudSyncEngine: CloudSyncEngine
    @StateObject private var auth = AuthEnvironment()
    /// App-level coordinator used by in-view surfaces (e.g. the face chip
    /// strip in photo detail) to request a Search-tab scope+query switch.
    @StateObject private var deepLinks = DeepLinkCoordinator()

    /// AWS cloud-sync plumbing. Held as plain `let`s because `AWSPhotoSyncClient`
    /// and `CloudPushCoordinator` are actors — SwiftUI observation does not
    /// apply. `cloudPushCoordinator.start()` is kicked off from a `.task`
    /// modifier once the user is authenticated.
    private let cloudSyncClient: AWSPhotoSyncClient
    private let cloudPushCoordinator: CloudPushCoordinator

    /// CloudKit silent-push bridge — coalesces push wake-ups into debounced
    /// `sync()` calls on the `CloudSyncEngine`. Held as a plain `let` to mirror
    /// the `cloudPushCoordinator` pattern; observation isn't needed at the view
    /// layer.
    private let cloudTriggerBridge: CloudSyncTriggerBridge

    /// UIApplicationDelegate adapter that wakes on CloudKit silent push and
    /// forwards to `cloudSyncEngine.sync()`. Constructed separately (rather
    /// than via `@UIApplicationDelegateAdaptor`) because its init takes the
    /// engine; registered from `.onAppear` on the authenticated branch.
    private let pushDelegate: PushNotificationDelegate

    /// Shared holder so the AWS client's token-provider closure (created in
    /// `init`, before the `AuthEnvironment` StateObject has been materialized
    /// by SwiftUI) can resolve the real environment at request time.
    private let authHolder: AuthEnvironmentHolder

    init() {
        let db: AppDatabase
        do {
            db = try AppDatabase.makeShared()
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        appDatabase = db
        let engine = CloudSyncEngine(appDatabase: db)
        _cloudSyncEngine = StateObject(wrappedValue: engine)

        // The bridge and push-delegate share the same engine instance that the
        // StateObject wraps, so push-driven `sync()` calls mutate the same
        // observable state the UI is bound to.
        self.cloudTriggerBridge = CloudSyncTriggerBridge(engine: engine)
        self.pushDelegate = PushNotificationDelegate(engine: engine)

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

        // Periodic drain is sufficient to catch curation changes no matter
        // which layer wrote them, so we intentionally do NOT wire
        // PeerSyncService as a fallback here — the Multipeer path continues
        // to run independently via `syncService` and will pick up the same
        // dirty rows on its own cadence.
        self.cloudPushCoordinator = CloudPushCoordinator(
            appDatabase: db,
            syncClient: client,
            peerFallback: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated {
                    MobileTabView()
                        .environment(\.appDatabase, appDatabase)
                        .environmentObject(syncService)
                        .environmentObject(cloudSyncEngine)
                        .environmentObject(auth)
                        .environmentObject(deepLinks)
                        .onAppear {
                            // Hook UIApplication for silent remote pushes.
                            // Safe to call every appear — UIKit coalesces.
                            // Only register when CloudKit sync is enabled;
                            // otherwise we shouldn't be asking the system for
                            // push tokens at all.
                            if CloudSyncEngine.isEnabled {
                                pushDelegate.register()
                            }
                        }
                        .task {
                            await authHolder.bind { [auth] in
                                await auth.currentIdToken()
                            }
                            // Gate all CloudKit-adjacent services behind the
                            // user-toggled feature flag. When disabled we only
                            // run the AWS push coordinator (independent sync
                            // path) so the app remains functional without an
                            // iCloud developer entitlement.
                            if CloudSyncEngine.isEnabled {
                                cloudSyncEngine.startAutoSync()
                                // Debounced CloudKit silent-push → sync() bridge.
                                cloudTriggerBridge.start()
                                // TODO: expose subscribe() on CloudSyncEngine
                                // (currently `subscribeToChanges()` is internal to
                                // HoehnPhotosCore, so we cannot invoke it from
                                // the mobile app target). Once it is made public,
                                // add: `try? await cloudSyncEngine.subscribeToChanges()`
                            }
                            await cloudPushCoordinator.start()
                            // Park until SwiftUI cancels this `.task` (e.g.
                            // the user signs out and the branch is torn down)
                            // so we can gracefully stop the coordinator loop.
                            do {
                                while !Task.isCancelled {
                                    try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                                }
                            } catch {
                                // Cancellation — fall through to stop().
                            }
                            if CloudSyncEngine.isEnabled {
                                cloudTriggerBridge.stop()
                                cloudSyncEngine.stopAutoSync()
                            }
                            await cloudPushCoordinator.stop()
                        }
                } else {
                    LoginView()
                        .environmentObject(auth)
                        .task {
                            // Bind the token resolver so that on first sign-in
                            // the AWS client can fetch an id-token the instant
                            // the user lands on the authenticated tree.
                            await authHolder.bind { [auth] in
                                await auth.currentIdToken()
                            }
                        }
                }
            }
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
