//
//  AWSPullCoordinator.swift
//  HoehnPhotosCore
//
//  Periodic cloud pull: fetches server-side catalog changes via
//  `AWSPhotoSyncClient.pullCatalogChanges(...)` and applies them to the local
//  GRDB catalog (photo_assets, person_identities, face_embeddings) without
//  clobbering pending local edits that haven't been pushed yet.
//
//  Design notes
//    - Cursor-based: stores the last-seen `syncTimestamp` (returned by the
//      server) in `UserDefaults` as an ISO-8601 string. Epoch 0 on first run.
//    - Conflict resolution (per row):
//        * No local row         → insert.
//        * local.aws_synced_at IS NOT NULL
//          AND local.updated_at > remote.updated_at → skip (pending local
//          edit — CloudPushCoordinator will push it). This is the "don't
//          clobber pending-local edits" guarantee.
//        * Otherwise             → remote wins; we also stamp
//          `aws_synced_at = remote.updated_at` so the next push loop does
//          NOT see this row as dirty and immediately push it back.
//    - Only the columns known to change via the push side are mirrored on
//      the pull side:
//        photos:  curation_state, user_metadata_json, scene_type, is_grayscale
//        people:  name, cover_face_embedding_id
//        faces:   person_id, labeled_by, needs_review
//      Everything else the server sends is ignored. New-row inserts fill
//      the NOT-NULL columns with safe defaults so the row is valid under
//      the iOS minimal schema.
//    - On `.unauthenticated` we no-op — the user needs to re-authenticate
//      before anything else can make progress.
//    - Network / 5xx / decoding failures are logged and swallowed. The
//      loop re-schedules normally; the cursor is NOT advanced on failure,
//      so the next tick will re-fetch the same window.
//
//  Concurrency: `actor`-owned loop, same shape as `CloudPushCoordinator`.
//  The periodic task ticks every `interval` seconds and re-checks
//  `isRunning` before each pull, so `stop()` takes effect within one tick.
//

import Foundation
import GRDB
import os

public actor AWSPullCoordinator {

    // MARK: - Stored

    private let appDatabase: AppDatabase
    private let syncClient: AWSPhotoSyncClient
    private let lastPulledAtKey: String
    private let defaults: UserDefaults

    private let logger = Logger(
        subsystem: "com.hoehn-photos.sync",
        category: "AWSPullCoordinator"
    )

    /// Per-fetch cap sent to `/sync/catalog`.
    private static let fetchLimit = 500

    private var isRunning = false
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        appDatabase: AppDatabase,
        syncClient: AWSPhotoSyncClient,
        lastPulledAtKey: String = "com.hoehn-photos.aws.lastPulledAt"
    ) {
        self.appDatabase = appDatabase
        self.syncClient = syncClient
        self.lastPulledAtKey = lastPulledAtKey
        self.defaults = UserDefaults.standard
    }

    // MARK: - Public API

    /// Start the periodic pull loop. Safe to call multiple times — the
    /// second call is a no-op while the first loop is still running.
    public func start(interval: TimeInterval = 30) async {
        guard !isRunning else {
            logger.debug("start: already running — ignoring")
            return
        }
        isRunning = true
        logger.notice("start: launching pull loop (interval=\(interval, privacy: .public)s)")

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

    /// Stop the periodic pull loop. In-flight pulls will complete, but the
    /// next tick is skipped.
    public func stop() async {
        logger.notice("stop: requested")
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
    }

    /// Immediate pull — intended for push-notification / user-triggered refresh.
    /// Safe to call even when the periodic loop is not running.
    public func drainNow() async {
        let since = loadLastPulledAt()
        logger.debug("drainNow: pulling since=\(since.timeIntervalSince1970, privacy: .public)")

        let items: [[String: AnyCodable]]
        let nextSince: Date?
        do {
            let result = try await syncClient.pullCatalogChanges(
                since: since,
                entityType: nil,
                limit: Self.fetchLimit
            )
            items = result.items
            nextSince = result.nextSince
        } catch let err as AWSPhotoSyncClient.Error {
            switch err {
            case .unauthenticated:
                logger.warning("drainNow: unauthenticated — skipping pull")
            case .forbidden:
                logger.warning("drainNow: forbidden — skipping pull")
            case .rateLimited:
                logger.notice("drainNow: rate limited — will retry on next tick")
            case .networkError, .httpError, .decodingError:
                logger.error("drainNow: pull failed \(String(describing: err), privacy: .public)")
            }
            return
        } catch {
            logger.error("drainNow: unexpected pull error \(String(describing: error), privacy: .public)")
            return
        }

        logger.debug("drainNow: received \(items.count, privacy: .public) items")

        var applied = 0
        var skipped = 0
        for raw in items {
            do {
                let parsed = try Self.parseItem(raw)
                let didApply = try await applyItem(parsed)
                if didApply { applied += 1 } else { skipped += 1 }
            } catch {
                logger.error("drainNow: failed to apply item \(String(describing: error), privacy: .public)")
            }
        }

        // Advance the cursor on success. If the server didn't echo a
        // syncTimestamp (shouldn't happen for a 200), fall back to `now` so
        // we don't re-pull the same window forever.
        let cursor = nextSince ?? Date()
        storeLastPulledAt(cursor)
        logger.notice(
            "drainNow: applied=\(applied, privacy: .public) skipped=\(skipped, privacy: .public) cursor=\(Self.iso8601(cursor), privacy: .public)"
        )
    }

    // MARK: - Internal — loop control

    private func shouldKeepRunning() -> Bool {
        isRunning
    }

    // MARK: - Cursor persistence

    private func loadLastPulledAt() -> Date {
        guard let s = defaults.string(forKey: lastPulledAtKey),
              let d = Self.parseISO8601(s)
        else {
            return Date(timeIntervalSince1970: 0)
        }
        return d
    }

    private func storeLastPulledAt(_ date: Date) {
        defaults.set(Self.iso8601(date), forKey: lastPulledAtKey)
    }

    // MARK: - Item parsing

    /// Structured view of a catalog item as returned by GET /sync/catalog.
    private struct ParsedItem {
        let entityType: String
        let entityId: String
        let updatedAt: Date
        let payload: [String: AnyCodable]
    }

    private enum ParseError: Swift.Error {
        case missingField(String)
        case unsupportedEntityType(String)
    }

    /// Pull a strongly-typed `ParsedItem` out of the loose `[String: AnyCodable]`
    /// shape returned by `AWSPhotoSyncClient.pullCatalogChanges`.
    private static func parseItem(_ raw: [String: AnyCodable]) throws -> ParsedItem {
        guard let type = (raw["entityType"]?.value as? String), !type.isEmpty else {
            throw ParseError.missingField("entityType")
        }
        guard let id = (raw["entityId"]?.value as? String), !id.isEmpty else {
            throw ParseError.missingField("entityId")
        }
        let updatedAt: Date
        if let epoch = raw["updatedAt"]?.value as? Int64 {
            updatedAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let epoch = raw["updatedAt"]?.value as? Int {
            updatedAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let epoch = raw["updatedAt"]?.value as? Double {
            updatedAt = Date(timeIntervalSince1970: epoch)
        } else {
            throw ParseError.missingField("updatedAt")
        }

        // `data` is the per-entity payload. Some earlier server versions may
        // still include the columns inline; accept either shape defensively.
        let payload: [String: AnyCodable]
        if let data = raw["data"]?.value as? [String: AnyCodable] {
            payload = data
        } else {
            payload = raw
        }

        return ParsedItem(
            entityType: type,
            entityId: id,
            updatedAt: updatedAt,
            payload: payload
        )
    }

    // MARK: - Apply dispatch

    /// Route an item to the right upsert. Returns true if a write happened.
    private func applyItem(_ item: ParsedItem) async throws -> Bool {
        switch item.entityType {
        case "PHOTO":
            return try await upsertPhoto(item)
        case "PERSON":
            return try await upsertPerson(item)
        case "FACE":
            return try await upsertFace(item)
        default:
            logger.debug("applyItem: ignoring entityType=\(item.entityType, privacy: .public)")
            return false
        }
    }

    // MARK: - Upsert: photos

    private func upsertPhoto(_ item: ParsedItem) async throws -> Bool {
        let remoteUpdatedAtISO = Self.iso8601(item.updatedAt)
        let id = item.entityId
        let curationState = Self.string(item.payload["curationState"]) ?? "needs_review"
        let userMeta = Self.string(item.payload["userMetadataJson"])
        let sceneType = Self.string(item.payload["sceneType"])
        let isGrayscale = Self.bool(item.payload["isGrayscale"])
        let canonicalName = Self.string(item.payload["canonicalName"]) ?? id

        return try await appDatabase.dbPool.write { db in
            if let decision = try Self.photoConflictDecision(db: db, id: id, remoteUpdatedAtISO: remoteUpdatedAtISO) {
                switch decision {
                case .skip:
                    return false
                case .update:
                    try db.execute(sql: """
                        UPDATE photo_assets SET
                            curation_state = COALESCE(?, curation_state),
                            user_metadata_json = COALESCE(?, user_metadata_json),
                            scene_type = COALESCE(?, scene_type),
                            is_grayscale = COALESCE(?, is_grayscale),
                            updated_at = ?,
                            aws_synced_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            curationState,
                            userMeta,
                            sceneType,
                            isGrayscale,
                            remoteUpdatedAtISO,
                            remoteUpdatedAtISO,
                            id,
                        ]
                    )
                    return true
                }
            } else {
                // Insert — fill NOT-NULL columns with safe defaults. The
                // minimal iOS schema requires: id, canonical_name, role,
                // file_path, file_size, processing_state, curation_state,
                // sync_state, created_at, updated_at.
                try db.execute(sql: """
                    INSERT INTO photo_assets (
                        id, canonical_name, role, file_path, file_size,
                        processing_state, curation_state, sync_state,
                        user_metadata_json, scene_type, is_grayscale,
                        created_at, updated_at, aws_synced_at
                    ) VALUES (
                        ?, ?, 'master', '', 0,
                        'indexed', ?, 'remote',
                        ?, ?, ?,
                        ?, ?, ?
                    )
                    """,
                    arguments: [
                        id,
                        canonicalName,
                        curationState,
                        userMeta,
                        sceneType,
                        isGrayscale,
                        remoteUpdatedAtISO,
                        remoteUpdatedAtISO,
                        remoteUpdatedAtISO,
                    ]
                )
                return true
            }
        }
    }

    // MARK: - Upsert: people

    private func upsertPerson(_ item: ParsedItem) async throws -> Bool {
        let remoteUpdatedAtISO = Self.iso8601(item.updatedAt)
        let id = item.entityId
        let name = Self.string(item.payload["name"])
        let coverFaceId = Self.string(item.payload["coverFaceEmbeddingId"])

        return try await appDatabase.dbPool.write { db in
            if let decision = try Self.personConflictDecision(db: db, id: id, remoteUpdatedAtISO: remoteUpdatedAtISO) {
                switch decision {
                case .skip:
                    return false
                case .update:
                    try db.execute(sql: """
                        UPDATE person_identities SET
                            name = COALESCE(?, name),
                            cover_face_embedding_id = COALESCE(?, cover_face_embedding_id),
                            updated_at = ?,
                            aws_synced_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            name,
                            coverFaceId,
                            remoteUpdatedAtISO,
                            remoteUpdatedAtISO,
                            id,
                        ]
                    )
                    return true
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO person_identities (
                        id, name, cover_face_embedding_id,
                        created_at, updated_at, aws_synced_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        name,
                        coverFaceId,
                        remoteUpdatedAtISO,
                        remoteUpdatedAtISO,
                        remoteUpdatedAtISO,
                    ]
                )
                return true
            }
        }
    }

    // MARK: - Upsert: faces

    private func upsertFace(_ item: ParsedItem) async throws -> Bool {
        let remoteUpdatedAtISO = Self.iso8601(item.updatedAt)
        let id = item.entityId
        let personId = Self.string(item.payload["personId"])
        let labeledBy = Self.string(item.payload["labeledBy"])
        let needsReview = Self.bool(item.payload["needsReview"]) ?? false
        let photoId = Self.string(item.payload["photoId"])

        return try await appDatabase.dbPool.write { db in
            // face_embeddings has no updated_at — created_at doubles as
            // freshness marker in the push path. For conflict detection
            // against pending local edits, we compare against created_at
            // (ISO-8601 text), same column the push side uses.
            if let decision = try Self.faceConflictDecision(db: db, id: id, remoteUpdatedAtISO: remoteUpdatedAtISO) {
                switch decision {
                case .skip:
                    return false
                case .update:
                    try db.execute(sql: """
                        UPDATE face_embeddings SET
                            person_id = ?,
                            labeled_by = ?,
                            needs_review = ?,
                            aws_synced_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            personId,
                            labeledBy,
                            needsReview,
                            remoteUpdatedAtISO,
                            id,
                        ]
                    )
                    return true
                }
            } else {
                // face_embeddings is normally created by the macOS face
                // detector. Inserting a remote-originated face on iOS is
                // best-effort — we fill geometry with zeros and let the
                // next full sync snapshot overwrite it. If photo_id is
                // missing we skip (FK invariant in spirit).
                guard let photoId else {
                    return false
                }
                try db.execute(sql: """
                    INSERT INTO face_embeddings (
                        id, photo_id, face_index,
                        bbox_x, bbox_y, bbox_width, bbox_height,
                        feature_data, created_at,
                        person_id, labeled_by, needs_review,
                        aws_synced_at
                    ) VALUES (
                        ?, ?, 0,
                        0, 0, 0, 0,
                        NULL, ?,
                        ?, ?, ?,
                        ?
                    )
                    """,
                    arguments: [
                        id,
                        photoId,
                        remoteUpdatedAtISO,
                        personId,
                        labeledBy,
                        needsReview,
                        remoteUpdatedAtISO,
                    ]
                )
                return true
            }
        }
    }

    // MARK: - Conflict decision helpers
    //
    // Centralized so the three tables share one semantic: if the row
    // exists, decide whether to update (remote wins) or skip (pending
    // local edit). Returning `nil` means "no local row — caller should
    // insert".

    private enum ConflictDecision {
        case update
        case skip
    }

    /// Look up `(updated_at, aws_synced_at)` for a row and decide.
    private static func photoConflictDecision(
        db: Database,
        id: String,
        remoteUpdatedAtISO: String
    ) throws -> ConflictDecision? {
        try decide(
            db: db,
            sql: "SELECT updated_at AS ts, aws_synced_at AS syn FROM photo_assets WHERE id = ? LIMIT 1",
            id: id,
            remoteUpdatedAtISO: remoteUpdatedAtISO
        )
    }

    private static func personConflictDecision(
        db: Database,
        id: String,
        remoteUpdatedAtISO: String
    ) throws -> ConflictDecision? {
        try decide(
            db: db,
            sql: "SELECT updated_at AS ts, aws_synced_at AS syn FROM person_identities WHERE id = ? LIMIT 1",
            id: id,
            remoteUpdatedAtISO: remoteUpdatedAtISO
        )
    }

    private static func faceConflictDecision(
        db: Database,
        id: String,
        remoteUpdatedAtISO: String
    ) throws -> ConflictDecision? {
        // face_embeddings has no `updated_at` column — `created_at` is the
        // freshness marker used by the push path.
        try decide(
            db: db,
            sql: "SELECT created_at AS ts, aws_synced_at AS syn FROM face_embeddings WHERE id = ? LIMIT 1",
            id: id,
            remoteUpdatedAtISO: remoteUpdatedAtISO
        )
    }

    private static func decide(
        db: Database,
        sql: String,
        id: String,
        remoteUpdatedAtISO: String
    ) throws -> ConflictDecision? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [id]) else {
            return nil
        }
        let localUpdatedAt = row["ts"] as String?
        let localAwsSyncedAt = row["syn"] as String?

        // Pending local edit: row has been touched after its last AWS push
        // (or never pushed) AND its timestamp is newer than the incoming
        // remote write. Skip so the push side can send the local change up.
        if let localAwsSyncedAt,
           !localAwsSyncedAt.isEmpty,
           let localUpdatedAt,
           localUpdatedAt > remoteUpdatedAtISO {
            return .skip
        }
        return .update
    }

    // MARK: - Helpers

    private static func string(_ any: AnyCodable?) -> String? {
        guard let v = any?.value else { return nil }
        if v is NSNull { return nil }
        return v as? String
    }

    private static func bool(_ any: AnyCodable?) -> Bool? {
        guard let v = any?.value else { return nil }
        if v is NSNull { return nil }
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        if let i = v as? Int64 { return i != 0 }
        return nil
    }

    /// Parse an ISO8601 string (with or without fractional seconds) to a Date.
    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
