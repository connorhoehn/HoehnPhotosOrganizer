//
//  CloudPushCoordinator.swift
//  HoehnPhotosCore
//
//  Periodic cloud push: drains the dirty-row queues from the local SQLite
//  catalog (photo_assets, person_identities, face_embeddings) and forwards
//  them to the AWS sync API via `AWSPhotoSyncClient`.
//
//  Design notes
//    - Cloud-first: on a successful `uploadCatalogBatch` we call the
//      matching `mark…AWSSynced` helpers so the rows fall out of the
//      dirty query next time around.
//    - Peer as fallback: on network / 5xx failures we hand the equivalent
//      delta to `PeerSyncService` so a local Mac (if reachable) can still
//      receive the change until the cloud comes back. The dirty row is
//      NOT marked as synced in that case — the next drain will retry.
//    - On `.unauthenticated` we simply skip the drain; the user needs to
//      re-authenticate before anything else can proceed.
//
//  Concurrency: this is an `actor` that owns the loop. The periodic task
//  ticks every `interval` seconds and re-checks `isRunning` before each
//  drain, so `stop()` takes effect within one tick.
//

import Foundation
import os

public actor CloudPushCoordinator {

    // MARK: - Stored

    private let appDatabase: AppDatabase
    private let syncClient: AWSPhotoSyncClient
    private let peerFallback: PeerSyncService?

    private let photoRepo: MobilePhotoRepository
    private let peopleRepo: MobilePeopleRepository

    private let logger = Logger(
        subsystem: "com.hoehn-photos.sync",
        category: "CloudPushCoordinator"
    )

    /// Batch size for a single `uploadCatalogBatch` POST.
    private static let batchSize = 100

    /// Per-fetch cap so one drain never pulls millions of rows.
    private static let fetchLimit = 500

    private var isRunning = false
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        syncClient: AWSPhotoSyncClient,
        peerFallback: PeerSyncService? = nil
    ) {
        self.appDatabase = appDatabase
        self.syncClient = syncClient
        self.peerFallback = peerFallback
        self.photoRepo = MobilePhotoRepository(db: appDatabase)
        self.peopleRepo = MobilePeopleRepository(db: appDatabase)
    }

    // MARK: - Public API

    /// Start the periodic drain loop. Safe to call multiple times — the
    /// second call is a no-op while the first loop is still running.
    public func start(interval: TimeInterval = 15) async {
        guard !isRunning else {
            logger.debug("start: already running — ignoring")
            return
        }
        isRunning = true
        logger.notice("start: launching drain loop (interval=\(interval, privacy: .public)s)")

        loopTask = Task { [weak self] in
            guard let self else { return }
            let nanos = UInt64(max(1.0, interval) * 1_000_000_000)
            while await self.shouldKeepRunning() {
                await self.drainNow()
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    // Cancellation — exit cleanly.
                    break
                }
            }
        }
    }

    /// Stop the periodic drain loop. In-flight drains will complete, but
    /// the next tick is skipped.
    public func stop() async {
        logger.notice("stop: requested")
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
    }

    /// Immediate drain — intended for explicit user actions ("pull to sync").
    /// Safe to call even when the periodic loop is not running.
    public func drainNow() async {
        do {
            try await drainPhotos()
        } catch {
            logger.error("drainNow: drainPhotos threw \(String(describing: error), privacy: .public)")
        }
        do {
            try await drainPeople()
        } catch {
            logger.error("drainNow: drainPeople threw \(String(describing: error), privacy: .public)")
        }
        do {
            try await drainFaces()
        } catch {
            logger.error("drainNow: drainFaces threw \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internal — loop control

    private func shouldKeepRunning() -> Bool {
        isRunning
    }

    // MARK: - Internal — drain: photos

    private func drainPhotos() async throws {
        let rows = try await photoRepo.fetchDirtyPhotosForAWS(limit: Self.fetchLimit)
        guard !rows.isEmpty else { return }
        logger.debug("drainPhotos: \(rows.count, privacy: .public) dirty rows")

        let items: [AWSPhotoSyncClient.CatalogItem] = rows.map { row in
            var payload: [String: AnyCodable] = [
                "id": AnyCodable(row.id),
                "curationState": AnyCodable(row.curationState),
            ]
            if let exif = row.rawExifJson { payload["rawExifJson"] = AnyCodable(exif) }
            if let meta = row.userMetadataJson { payload["userMetadataJson"] = AnyCodable(meta) }
            if let gray = row.isGrayscale { payload["isGrayscale"] = AnyCodable(gray) }
            if let scene = row.sceneType { payload["sceneType"] = AnyCodable(scene) }
            return AWSPhotoSyncClient.CatalogItem(
                entityId: row.id,
                entityType: "PHOTO",
                payload: payload,
                updatedAt: Self.parseISO8601(row.updatedAt) ?? Date()
            )
        }

        let chunks = items.chunked(into: Self.batchSize)
        let idsByChunkIndex = rows.chunked(into: Self.batchSize).map { $0.map(\.id) }

        for (idx, chunk) in chunks.enumerated() {
            let chunkIds = idsByChunkIndex[idx]
            do {
                try await syncClient.uploadCatalogBatch(chunk)
                let syncedAt = Self.iso8601Now()
                try await photoRepo.markPhotosAWSSynced(ids: chunkIds, syncedAt: syncedAt)
                logger.notice("drainPhotos: pushed \(chunk.count, privacy: .public) photos")
            } catch let err as AWSPhotoSyncClient.Error {
                switch err {
                case .unauthenticated:
                    logger.warning("drainPhotos: unauthenticated — leaving \(chunkIds.count, privacy: .public) rows dirty")
                    return
                case .forbidden:
                    logger.error("drainPhotos: forbidden — leaving rows dirty")
                    return
                case .rateLimited:
                    logger.notice("drainPhotos: rate limited — will retry on next tick")
                    return
                case .networkError, .httpError, .decodingError:
                    logger.error("drainPhotos: AWS failure — falling back to peer (err=\(String(describing: err), privacy: .public))")
                    await peerFallbackPhotos(rows: rows.filter { chunkIds.contains($0.id) })
                    return
                }
            } catch {
                logger.error("drainPhotos: unexpected error \(String(describing: error), privacy: .public)")
                await peerFallbackPhotos(rows: rows.filter { chunkIds.contains($0.id) })
                return
            }
        }
    }

    // MARK: - Internal — drain: people

    private func drainPeople() async throws {
        let rows = try await peopleRepo.fetchDirtyPeopleForAWS(limit: Self.fetchLimit)
        guard !rows.isEmpty else { return }
        logger.debug("drainPeople: \(rows.count, privacy: .public) dirty rows")

        let items: [AWSPhotoSyncClient.CatalogItem] = rows.map { row in
            var payload: [String: AnyCodable] = [
                "id": AnyCodable(row.id),
            ]
            if let name = row.name { payload["name"] = AnyCodable(name) }
            if let cover = row.coverFaceEmbeddingId { payload["coverFaceEmbeddingId"] = AnyCodable(cover) }
            return AWSPhotoSyncClient.CatalogItem(
                entityId: row.id,
                entityType: "PERSON",
                payload: payload,
                updatedAt: Self.parseISO8601(row.updatedAt) ?? Date()
            )
        }

        let chunks = items.chunked(into: Self.batchSize)
        let rowChunks = rows.chunked(into: Self.batchSize)

        for (idx, chunk) in chunks.enumerated() {
            let chunkIds = rowChunks[idx].map(\.id)
            do {
                try await syncClient.uploadCatalogBatch(chunk)
                let syncedAt = Self.iso8601Now()
                try await peopleRepo.markPeopleAWSSynced(ids: chunkIds, syncedAt: syncedAt)
                logger.notice("drainPeople: pushed \(chunk.count, privacy: .public) people")
            } catch let err as AWSPhotoSyncClient.Error {
                switch err {
                case .unauthenticated:
                    logger.warning("drainPeople: unauthenticated — leaving rows dirty")
                    return
                case .forbidden, .rateLimited:
                    logger.notice("drainPeople: \(String(describing: err), privacy: .public) — will retry")
                    return
                case .networkError, .httpError, .decodingError:
                    logger.error("drainPeople: AWS failure — falling back to peer")
                    await peerFallbackPeople(rows: rowChunks[idx])
                    return
                }
            } catch {
                logger.error("drainPeople: unexpected error \(String(describing: error), privacy: .public)")
                await peerFallbackPeople(rows: rowChunks[idx])
                return
            }
        }
    }

    // MARK: - Internal — drain: faces

    private func drainFaces() async throws {
        let rows = try await peopleRepo.fetchDirtyFacesForAWS(limit: Self.fetchLimit)
        guard !rows.isEmpty else { return }
        logger.debug("drainFaces: \(rows.count, privacy: .public) dirty rows")

        let items: [AWSPhotoSyncClient.CatalogItem] = rows.map { row in
            var payload: [String: AnyCodable] = [
                "id": AnyCodable(row.id),
                "photoId": AnyCodable(row.photoId),
                "needsReview": AnyCodable(row.needsReview),
            ]
            if let pid = row.personId { payload["personId"] = AnyCodable(pid) }
            if let lbl = row.labeledBy { payload["labeledBy"] = AnyCodable(lbl) }
            return AWSPhotoSyncClient.CatalogItem(
                entityId: row.id,
                entityType: "FACE",
                payload: payload,
                // face_embeddings has no updated_at — createdAt doubles as freshness marker.
                updatedAt: Self.parseISO8601(row.createdAt) ?? Date()
            )
        }

        let chunks = items.chunked(into: Self.batchSize)
        let rowChunks = rows.chunked(into: Self.batchSize)

        for (idx, chunk) in chunks.enumerated() {
            let chunkIds = rowChunks[idx].map(\.id)
            do {
                try await syncClient.uploadCatalogBatch(chunk)
                let syncedAt = Self.iso8601Now()
                try await peopleRepo.markFacesAWSSynced(ids: chunkIds, syncedAt: syncedAt)
                logger.notice("drainFaces: pushed \(chunk.count, privacy: .public) faces")
            } catch let err as AWSPhotoSyncClient.Error {
                switch err {
                case .unauthenticated:
                    logger.warning("drainFaces: unauthenticated — leaving rows dirty")
                    return
                case .forbidden, .rateLimited:
                    logger.notice("drainFaces: \(String(describing: err), privacy: .public) — will retry")
                    return
                case .networkError, .httpError, .decodingError:
                    logger.error("drainFaces: AWS failure — falling back to peer")
                    await peerFallbackFaces(rows: rowChunks[idx])
                    return
                }
            } catch {
                logger.error("drainFaces: unexpected error \(String(describing: error), privacy: .public)")
                await peerFallbackFaces(rows: rowChunks[idx])
                return
            }
        }
    }

    // MARK: - Peer fallback

    private func peerFallbackPhotos(rows: [DirtyPhotoRow]) async {
        guard let peerFallback else { return }
        let deltas = rows.map { row in
            PhotoCurationDelta(photoId: row.id, curationState: row.curationState)
        }
        await MainActor.run {
            for d in deltas { peerFallback.enqueueDelta(d) }
        }
    }

    private func peerFallbackPeople(rows: [DirtyPersonRow]) async {
        guard let peerFallback else { return }
        // We can't distinguish create vs rename from a dirty row alone, so
        // conservatively emit a renamePerson delta when a name is present;
        // rows with nil names are skipped (a rename to nil is not
        // representable by the current PEOPLE_V1 protocol).
        let deltas: [PeopleSyncDelta] = rows.compactMap { row in
            guard let name = row.name else { return nil }
            return .renamePerson(id: row.id, name: name, updatedAt: row.updatedAt)
        }
        guard !deltas.isEmpty else { return }
        await MainActor.run {
            for d in deltas { peerFallback.enqueuePeopleDelta(d) }
        }
    }

    private func peerFallbackFaces(rows: [DirtyFaceRow]) async {
        guard let peerFallback else { return }
        let deltas: [PeopleSyncDelta] = rows.map { row in
            if let personId = row.personId {
                return .assignFace(
                    faceId: row.id,
                    personId: personId,
                    labeledBy: row.labeledBy ?? "user",
                    updatedAt: row.createdAt
                )
            } else {
                return .unassignFace(faceId: row.id, updatedAt: row.createdAt)
            }
        }
        await MainActor.run {
            for d in deltas { peerFallback.enqueuePeopleDelta(d) }
        }
    }

    // MARK: - Helpers

    /// Parse an ISO8601 string (with or without fractional seconds) to a Date.
    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

// Note: `Array.chunked(into:)` is defined module-wide in `CloudSyncPush.swift`
// and used here as-is.

