// AWSSyncServiceFactory.swift
// HoehnPhotosOrganizer
//
// Creates the full AWS sync client graph with authenticated HTTP sessions.
// Centralizes construction so the App entry point stays clean.
//
// Dependency graph:
//   CognitoAuthManager
//     -> AuthenticatedURLSession (HTTPDataProvider with Bearer token injection)
//       -> ThreadSyncClient
//       -> CatalogSyncClient
//       -> S3PresignedURLProvider -> ProxySyncClient
//       -> CurveFileSyncClient (via S3Uploading)
//     -> IncrementalSyncCoordinator
//       -> BackgroundSyncCoordinator
//     -> SyncProgressViewModel
//
// Usage:
//   guard AWSConfigurationManager.shared.isSyncReady else { return nil }
//   let factory = AWSSyncServiceFactory(db: appDatabase)
//   let services = factory.build()
//   // services.backgroundSync.startPeriodicSync()

import Foundation

// MARK: - AWSSyncServices

/// Container for all AWS sync service instances.
/// Returned by AWSSyncServiceFactory.build().
struct AWSSyncServices {
    let authManager: CognitoAuthManager
    let authenticatedSession: AuthenticatedURLSession
    let threadSyncClient: ThreadSyncClient
    let catalogSyncClient: CatalogSyncClient
    let s3URLProvider: S3PresignedURLProvider
    let proxySyncClient: ProxySyncClient
    let incrementalSync: IncrementalSyncCoordinator
    let backgroundSync: BackgroundSyncCoordinator
    let conflictResolver: ConflictResolver
    let syncProgressViewModel: SyncProgressViewModel
}

// MARK: - AWSSyncServiceFactory

struct AWSSyncServiceFactory {
    let db: AppDatabase

    /// Build the complete sync service graph using current AWS configuration.
    /// Returns nil if configuration is incomplete.
    /// Must be called from the main actor (SyncProgressViewModel requires @MainActor).
    @MainActor
    func build() -> AWSSyncServices? {
        let config = AWSConfigurationManager.shared.current
        guard config.isComplete else { return nil }

        // 1. Auth layer
        let authManager = CognitoAuthManager()
        let authenticatedSession = AuthenticatedURLSession(authManager: authManager)

        // 2. Sync clients — all share the authenticated session
        let threadSyncClient = ThreadSyncClient(
            apiEndpoint: config.apiEndpoint,
            session: authenticatedSession
        )

        let catalogSyncClient = CatalogSyncClient(
            apiEndpoint: config.apiEndpoint,
            session: authenticatedSession
        )

        let presignEndpoint = URL(string: "\(config.apiEndpoint)/presign")!
        let s3URLProvider = S3PresignedURLProvider(
            presignEndpoint: presignEndpoint,
            session: authenticatedSession
        )

        let s3Client = PresignedS3Uploader(urlProvider: s3URLProvider)

        let proxySyncClient = ProxySyncClient(
            s3Client: s3Client,
            urlProvider: s3URLProvider
        )

        // 3. Repositories
        let syncStateRepo = SyncStateRepository(db: db)
        let threadRepo = ThreadRepository(db: db)

        // 4. Conflict resolution
        let conflictResolver = ConflictResolver()

        // 5. Sync coordinators
        let incrementalSync = IncrementalSyncCoordinator(
            syncStateRepo: syncStateRepo,
            threadSyncClient: threadSyncClient,
            threadRepo: threadRepo,
            conflictResolver: conflictResolver
        )

        let backgroundSync = BackgroundSyncCoordinator(
            syncCoordinator: incrementalSync
        )

        // 6. Progress view model (must be created on MainActor)
        let syncProgressViewModel = SyncProgressViewModel(
            db: db,
            incrementalSync: incrementalSync,
            conflictResolver: conflictResolver
        )

        return AWSSyncServices(
            authManager: authManager,
            authenticatedSession: authenticatedSession,
            threadSyncClient: threadSyncClient,
            catalogSyncClient: catalogSyncClient,
            s3URLProvider: s3URLProvider,
            proxySyncClient: proxySyncClient,
            incrementalSync: incrementalSync,
            backgroundSync: backgroundSync,
            conflictResolver: conflictResolver,
            syncProgressViewModel: syncProgressViewModel
        )
    }
}

// MARK: - PresignedS3Uploader

/// S3Uploading implementation that uses presigned PUT URLs from the Lambda endpoint.
/// This bridges the S3Uploading protocol (used by ProxySyncClient) to the
/// S3PresignedURLProvider + URLSession pattern.
struct PresignedS3Uploader: S3Uploading {
    private let urlProvider: S3PresignedURLProvider

    init(urlProvider: S3PresignedURLProvider) {
        self.urlProvider = urlProvider
    }

    func put(
        bucket: String,
        key: String,
        data: Data,
        contentType: String,
        metadata: [String: String]
    ) async throws -> Int {
        let presignedURL = try await urlProvider.presignedPutURL(for: key, contentType: contentType)

        var request = URLRequest(url: presignedURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        // Add metadata as x-amz-meta- headers
        for (metaKey, metaValue) in metadata {
            request.setValue(metaValue, forHTTPHeaderField: "x-amz-meta-\(metaKey)")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return -1
        }
        return httpResponse.statusCode
    }
}
