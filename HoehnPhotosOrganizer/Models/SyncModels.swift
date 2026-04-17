// SyncModels.swift
// HoehnPhotosOrganizer
//
// Cloud sync contracts: Swift types for ThreadEntry (cloud), PrintAttempt (cloud),
// SyncPayload, SyncStatus, and ConflictRule strategy.
//
// Architecture notes:
//   - Local SQLite is the source of truth; cloud (S3 + DynamoDB) is the durable backup layer.
//   - These types mirror the DynamoDB table schema for the thread-entry model:
//       Partition key: threadRootId (photo canonical_id, e.g. "IMG_1234.CR3")
//       Sort key: "<timestamp>#<entryId>"  (enables chronological GSI replay)
//   - All cloud timestamps are Unix epoch (Int64, seconds). Dates stored locally use
//     Foundation.Date but are serialized as epoch seconds when sent to the API.
//   - All types conform to Sendable so they can safely cross Swift 6 concurrency boundaries
//     (actor-to-actor, Task-to-Task, etc.).
//   - SyncStatus drives the per-photo icon badge in LibraryView.
//   - ConflictRule is a strategy pattern; callers inject the rule at sync time.

import Foundation

// MARK: - SyncThreadEntry
//
// Cloud representation of a thread entry stored in DynamoDB.
// This is distinct from the local GRDB-backed ThreadEntry model (ThreadEntry.swift),
// which uses snake_case DB column names. SyncThreadEntry uses camelCase for JSON
// encoding/decoding against the Lambda API.
//
// DynamoDB GSI usage:
//   Primary table: PK = threadRootId, SK = "<timestamp>#<entryId>"
//   GSI "byThreadRoot": PK = threadRootId, SK = timestamp
//   Queries for all entries of a photo: GSI query on threadRootId, ascending timestamp
//   Conflict detection: compare entryId lexicographically when timestamps collide

struct SyncThreadEntry: Codable, Identifiable, Sendable {
    /// Photo canonical ID — DynamoDB partition key.
    /// Matches canonical_name in the local PhotoAsset record (e.g. "IMG_1234.CR3").
    let threadRootId: String

    /// UUID string — part of the DynamoDB sort key: "<timestamp>#<entryId>".
    let entryId: String

    /// Unix epoch seconds — first component of sort key, enables chronological replay.
    let timestamp: Int64

    /// Entry kind. Maps to the `kind` column in local ThreadEntry.
    let type: EntryType

    /// JSON-serialized entry payload (notes text, AI conversation turn, print attempt fields, etc.).
    let content: String

    /// Unix epoch seconds at which this entry was written to DynamoDB. Nil if not yet synced.
    let syncedAt: Int64?

    // Identifiable conformance uses entryId (globally unique UUID).
    var id: String { entryId }

    enum EntryType: String, Codable, Sendable {
        case note
        case aiTurn        = "ai_turn"
        case printAttempt  = "print_attempt"
    }
}

// MARK: - SyncPrintAttempt
//
// Cloud representation of a versioned print attempt.
// The local PrintAttempt model (PrintAttempt.swift) is the authoritative record;
// SyncPrintAttempt is the wire format used when uploading to or restoring from DynamoDB.
//
// S3 curve file path convention:
//   curves/{photoId}_{id}.acv   (e.g. "curves/IMG_1234.CR3_B8F2-....acv")
// This matches the s3_curves_prefix in config.json ("curves/").

struct SyncPrintAttempt: Codable, Identifiable, Sendable {
    /// UUID string — primary identifier.
    let id: String

    /// Photo canonical ID (matches threadRootId convention).
    let photoId: String

    /// Print process type.
    let printType: SyncPrintType

    /// Paper description (brand, weight, surface). Optional — recorded when known.
    let paper: String?

    /// Ink description (brand, profile). Optional — inkjet processes only.
    let ink: String?

    /// S3 object key for the curve file. Pattern: curves/{photoId}_{id}.acv
    /// Nil when no curve file was used or uploaded.
    let curveFileS3Key: String?

    /// Outcome notes describing result quality, adjustments needed, etc.
    let outcome: String?

    /// Record creation timestamp (ISO8601). Stored as Date for convenience.
    let createdAt: Date

    /// Last modification timestamp.
    let updatedAt: Date

    /// Cloud sync timestamp. Nil = local only.
    let syncedAt: Date?
}

/// Print process types for the cloud wire format.
/// Mirrors PrintType in PrintType.swift but uses simpler raw values for API transport.
enum SyncPrintType: String, Codable, Sendable {
    case inkjetColor       = "inkjet_color"
    case inkjetBW          = "inkjet_bw"
    case silverGelatin     = "silver_gelatin"
    case platinumPalladium = "platinum_palladium"
    case cyanotype
    case digitalNegative   = "digital_negative"
}

// MARK: - SyncPayload
//
// Envelope for upload and download operations.
// Used when the Swift client talks to the Lambda sync API.
//
// Binary assets (proxies, curve files) flow via presigned S3 URLs — `content` is
// populated for these. JSON assets (threads, print records) use `jsonContent`.
//
// Checksum: SHA-256 hex digest of the raw asset bytes. Used for deduplication:
//   - Upload: server checks if checksum already exists in DynamoDB → skips re-upload
//   - Download: client verifies checksum after receiving presigned-URL content

struct SyncPayload: Codable, Sendable {
    /// Direction of the operation.
    let operation: SyncOperation

    /// Asset category determines which S3 prefix and DynamoDB table are used.
    let assetType: AssetType

    /// Photo canonical ID (or file UUID for curve files).
    let canonicalId: String

    /// Binary payload — used for proxy images and curve files.
    let content: Data?

    /// JSON payload — used for thread entries and print attempt records.
    let jsonContent: String?

    /// Unix epoch seconds at which this payload was created on the client.
    let timestamp: Int64

    /// SHA-256 hex digest for deduplication and integrity verification.
    let checksum: String
}

/// Upload vs. download direction.
enum SyncOperation: String, Codable, Sendable {
    case upload
    case download
}

/// Asset category — determines S3 prefix and Lambda handler.
enum AssetType: String, Codable, Sendable {
    /// JPEG proxy image (≤ 1600 px longest edge). S3 prefix: proxies/
    case proxy

    /// Thread entry JSON. DynamoDB table record. S3 prefix: threads/ (for batch exports)
    case thread

    /// Print attempt JSON. Stored as thread entry of type print_attempt.
    case print

    /// Curve file (.acv, .csv, .cube, .lut). S3 prefix: curves/
    case curve
}

// MARK: - SyncStatus
//
// Per-photo sync state displayed as an icon badge in LibraryView and the detail panel.
//
// State transitions:
//   localOnly  --(sync triggered)--> syncing(progress:)
//   syncing    --(transfer done)-->  synced(timestamp:)
//   syncing    --(error)---------->  error(reason:)
//   error      --(retry)----------> syncing(progress:)
//   synced     --(local edit)-----> localOnly  [re-sync needed]
//
// Persistence: SyncStatus is encoded as a JSON string in the local SQLite
// photo_assets table (column: sync_status_json). The associated type values
// (progress, timestamp, reason) round-trip through Codable.

enum SyncStatus: Sendable {
    /// Asset exists only on this device. No cloud copy.
    case localOnly

    /// Upload or download in progress. progress is 0.0–1.0.
    case syncing(progress: Double)

    /// Asset successfully mirrored in S3/DynamoDB. timestamp is the sync completion time.
    case synced(timestamp: Date)

    /// Sync failed. reason describes the error (network, auth, checksum mismatch, etc.).
    case error(reason: String)
}

// MARK: SyncStatus: Codable
// Associated-value enums need manual Codable implementations.

extension SyncStatus: Codable {
    private enum CodingKey: String, Swift.CodingKey {
        case type, progress, timestamp, reason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .localOnly:
            try container.encode("localOnly", forKey: .type)
        case .syncing(let progress):
            try container.encode("syncing", forKey: .type)
            try container.encode(progress, forKey: .progress)
        case .synced(let timestamp):
            try container.encode("synced", forKey: .type)
            try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        case .error(let reason):
            try container.encode("error", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "localOnly":
            self = .localOnly
        case "syncing":
            let progress = try container.decode(Double.self, forKey: .progress)
            self = .syncing(progress: progress)
        case "synced":
            let epochSeconds = try container.decode(Double.self, forKey: .timestamp)
            self = .synced(timestamp: Date(timeIntervalSince1970: epochSeconds))
        case "error":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .error(reason: reason)
        default:
            self = .localOnly
        }
    }
}

// MARK: SyncStatus: Equatable
extension SyncStatus: Equatable {
    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.localOnly, .localOnly):
            return true
        case let (.syncing(lp), .syncing(rp)):
            return lp == rp
        case let (.synced(lt), .synced(rt)):
            return lt == rt
        case let (.error(lr), .error(rr)):
            return lr == rr
        default:
            return false
        }
    }
}

// MARK: - ConflictRule
//
// Strategy pattern for resolving concurrent edits to the same ThreadEntry.
//
// Conflict scenario:
//   Two devices both edit the thread for IMG_1234.CR3 while offline.
//   When both come online, the server holds both versions.
//   The sync client calls applyRule(local:remote:) to decide which wins.
//
// Design:
//   - ConflictRule is injected at call sites rather than hardcoded.
//   - Wave 3 (SyncClient actor) will use LastEditWinsConflictRule by default.
//   - Future: MergeConflictRule can concatenate non-overlapping note entries.

protocol ConflictRule: Sendable {
    /// Resolve a conflict between the local version and the remote (server) version.
    /// - Parameters:
    ///   - local: Entry as it exists in local SQLite.
    ///   - remote: Entry as it exists in DynamoDB.
    /// - Returns: Resolution indicating which entry to keep, or that user input is needed.
    func applyRule(local: SyncThreadEntry, remote: SyncThreadEntry) -> ConflictResolution
}

/// Outcome of a conflict resolution.
enum ConflictResolution: Sendable {
    /// Use the given entry and discard the other. winner is the authoritative version.
    case keep(SyncThreadEntry)

    /// Cannot auto-resolve; surface both versions to the user for manual choice.
    case userChoice(local: SyncThreadEntry, remote: SyncThreadEntry, message: String)
}

// MARK: - LastEditWinsConflictRule
//
// Default conflict resolution: the entry with the later timestamp wins.
// Tie-breaking: lexicographic comparison of entryId (UUID v4 strings).
//
// Rationale: In a photo workflow, the most recent note or print record reflects
// the photographer's current intent. Silent last-write-wins is acceptable for
// notes and AI turns; print attempts have unique IDs so conflicts are rare.

struct LastEditWinsConflictRule: ConflictRule, Sendable {
    func applyRule(local: SyncThreadEntry, remote: SyncThreadEntry) -> ConflictResolution {
        if local.timestamp > remote.timestamp {
            return .keep(local)
        } else if remote.timestamp > local.timestamp {
            return .keep(remote)
        } else {
            // Timestamps are equal — fall back to lexicographic entryId comparison.
            // Higher UUID string wins (deterministic, consistent across devices).
            let winner = local.entryId >= remote.entryId ? local : remote
            return .keep(winner)
        }
    }
}

// MARK: - UserChoiceConflictRule
//
// Alternative rule that always surfaces conflicts to the user.
// Useful for high-value content (e.g., long editorial notes) where silent overwrite
// would lose work that cannot be recovered.

struct UserChoiceConflictRule: ConflictRule, Sendable {
    func applyRule(local: SyncThreadEntry, remote: SyncThreadEntry) -> ConflictResolution {
        return .userChoice(
            local: local,
            remote: remote,
            message: "Both your device and another device edited this entry. Choose which version to keep."
        )
    }
}

// MARK: - Catalog Sync Types

enum CatalogEntityType: String, Codable, Sendable {
    case photo = "PHOTO"
    case job = "JOB"
    case person = "PERSON"
    case face = "FACE"
    case revision = "REVISION"
}

struct CatalogSyncItem: Codable, Sendable {
    let entityType: CatalogEntityType
    let entityId: String
    let updatedAt: Int64
    let payload: String  // JSON string of entity-specific fields
    let isDeleted: Bool

    init(entityType: CatalogEntityType, entityId: String, updatedAt: Int64, payload: String, isDeleted: Bool = false) {
        self.entityType = entityType
        self.entityId = entityId
        self.updatedAt = updatedAt
        self.payload = payload
        self.isDeleted = isDeleted
    }
}

struct CatalogBatchResponse: Codable, Sendable {
    let syncTimestamp: Int64
    let writtenCount: Int
}

struct CatalogPullResponse: Codable, Sendable {
    let items: [CatalogSyncItem]
    let nextToken: String?
    let syncTimestamp: Int64
}

// MARK: - Sync Progress Types

enum SyncOverallState: Sendable {
    case idle
    case syncing
    case error(String)
    case paused
    case disabled
}

struct SyncProgressUpdate: Sendable {
    enum Phase: Sendable {
        case uploadingThreads(completed: Int, total: Int)
        case uploadingCatalog(completed: Int, total: Int)
        case uploadingProxies(completed: Int, total: Int)
        case downloading
        case idle
        case error(String)
    }
    let phase: Phase
    let timestamp: Date
}
