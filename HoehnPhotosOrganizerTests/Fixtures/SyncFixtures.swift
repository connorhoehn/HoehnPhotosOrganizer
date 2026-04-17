// SyncFixtures.swift
// HoehnPhotosOrganizerTests
//
// Reusable test builders for Phase 4 cloud sync tests.
// Provides deterministic test data for upload, download, conflict, and error scenarios.

import Foundation

// MARK: - Canonical ID Constants

/// 50 deterministic canonical IDs used across sync tests.
/// Format mirrors camera-assigned filenames (unique per camera, stable across moves).
let testCanonicalIds: [String] = (1...50).map { i in
    String(format: "IMG_%04d.jpg", i)
}

/// 512 KB JPEG-like data for proxy upload/download tests.
/// Not a valid JPEG — just reproducible bytes for mock S3 transfer size verification.
let testProxyJPEGData: Data = {
    var bytes = [UInt8](repeating: 0xFF, count: 512 * 1024)
    // JPEG magic bytes at start
    bytes[0] = 0xFF; bytes[1] = 0xD8; bytes[2] = 0xFF; bytes[3] = 0xE0
    // JPEG end-of-image marker
    bytes[bytes.count - 2] = 0xFF; bytes[bytes.count - 1] = 0xD9
    return Data(bytes)
}()

/// Sample SQLite export SQL used for catalog export tests.
let testCatalogExportSQL = """
    CREATE TABLE photo_assets (canonical_name TEXT PRIMARY KEY, file_path TEXT, file_size INTEGER);
    INSERT INTO photo_assets VALUES ('IMG_0001.jpg', '/Volumes/Drive/IMG_0001.jpg', 24576000);
    INSERT INTO photo_assets VALUES ('IMG_0002.jpg', '/Volumes/Drive/IMG_0002.jpg', 18432000);
    """

// MARK: - Mock Photo Asset

/// Lightweight stand-in for a PhotoAsset during sync tests.
/// Carries just enough data to verify S3 key construction and proxy payload size.
struct MockPhotoAsset {
    let canonicalId: String
    let proxyData: Data
    let captureDate: Date
    let s3ProxyKey: String

    init(
        canonicalId: String = testCanonicalIds[0],
        proxyData: Data = testProxyJPEGData,
        captureDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.canonicalId = canonicalId
        self.proxyData = proxyData
        self.captureDate = captureDate
        self.s3ProxyKey = "proxies/\(canonicalId)"
    }
}

// MARK: - Mock Thread Entry

/// Represents a single editorial thread entry for DynamoDB sync tests.
/// Types mirror the thread model from lifeeventscloud architecture research.
struct MockThreadEntry {
    enum EntryType: String {
        case note
        case aiTurn = "ai_turn"
        case printAttempt = "print_attempt"
    }

    let entryId: String
    let threadRootId: String   // canonicalId of the parent photo
    let timestamp: Date
    let type: EntryType
    let content: String        // JSON string for ai_turn / printAttempt; plain text for note

    init(
        entryId: String = UUID().uuidString,
        threadRootId: String = testCanonicalIds[0],
        timestamp: Date = Date(),
        type: EntryType = .note,
        content: String = "Test note content"
    ) {
        self.entryId = entryId
        self.threadRootId = threadRootId
        self.timestamp = timestamp
        self.type = type
        self.content = content
    }

    /// DynamoDB sort key: ISO-8601 + entryId for stable chronological ordering.
    var sortKey: String {
        let formatter = ISO8601DateFormatter()
        return "\(formatter.string(from: timestamp))#\(entryId)"
    }
}

// MARK: - Mock Print Attempt

/// Represents a darkroom print attempt with associated curve file.
struct MockPrintAttempt {
    let attemptId: String
    let canonicalId: String
    let printType: String       // "darkroom" | "inkjet"
    let paper: String
    let curveFileReference: String   // S3 key for .acv file

    init(
        attemptId: String = UUID().uuidString,
        canonicalId: String = testCanonicalIds[0],
        printType: String = "darkroom",
        paper: String = "Ilford MGFB",
        curveFileReference: String? = nil
    ) {
        self.attemptId = attemptId
        self.canonicalId = canonicalId
        self.printType = printType
        self.paper = paper
        self.curveFileReference = curveFileReference ?? "curves/\(canonicalId)_\(attemptId).acv"
    }
}

// MARK: - Conflict Scenarios

/// Pre-built conflict scenarios for SYNC-10 tests.
enum SyncConflict {
    /// Same photo note edited on two machines with different timestamps.
    static func samePhotoEditedOnTwoMachines() -> (local: MockThreadEntry, remote: MockThreadEntry) {
        let threadRootId = testCanonicalIds[5]
        let t1 = Date(timeIntervalSince1970: 1_700_001_000) // Mac A edits first
        let t2 = Date(timeIntervalSince1970: 1_700_002_000) // Mac B edits later

        let local = MockThreadEntry(
            entryId: "local-edit-001",
            threadRootId: threadRootId,
            timestamp: t1,
            type: .note,
            content: "Mac A version of the note"
        )
        let remote = MockThreadEntry(
            entryId: "remote-edit-001",
            threadRootId: threadRootId,
            timestamp: t2,
            type: .note,
            content: "Mac B version of the note (newer)"
        )
        return (local, remote)
    }

    /// Thread entry added locally AND a different one added remotely — not a true conflict,
    /// but tests that both entries survive merge without overwriting each other.
    static func threadEntryAddedLocallyAndRemotely() -> (local: MockThreadEntry, remote: MockThreadEntry) {
        let threadRootId = testCanonicalIds[7]
        let base = Date(timeIntervalSince1970: 1_700_003_000)

        let local = MockThreadEntry(
            entryId: "local-new-entry",
            threadRootId: threadRootId,
            timestamp: base,
            type: .note,
            content: "Local-only new note"
        )
        let remote = MockThreadEntry(
            entryId: "remote-new-entry",
            threadRootId: threadRootId,
            timestamp: base.addingTimeInterval(5),
            type: .aiTurn,
            content: #"{"model":"llava:13b","response":"Grain is visible at high magnification."}"#
        )
        return (local, remote)
    }
}

// MARK: - Builder Helpers

/// Convenience factory for creating batches of mock entries in chronological order.
struct SyncFixtures {

    /// Returns `count` MockThreadEntries with evenly spaced timestamps (1 second apart).
    static func makeOrderedEntries(
        count: Int,
        threadRootId: String = testCanonicalIds[0],
        baseDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        type: MockThreadEntry.EntryType = .note
    ) -> [MockThreadEntry] {
        (0..<count).map { i in
            MockThreadEntry(
                entryId: "entry-\(String(format: "%04d", i))",
                threadRootId: threadRootId,
                timestamp: baseDate.addingTimeInterval(Double(i)),
                type: type,
                content: "Entry \(i) content"
            )
        }
    }

    /// Returns `count` MockPhotoAssets with sequential canonical IDs.
    static func makePhotoAssets(count: Int) -> [MockPhotoAsset] {
        (0..<min(count, testCanonicalIds.count)).map { i in
            MockPhotoAsset(canonicalId: testCanonicalIds[i])
        }
    }

    /// Returns a 1 MB content string for large-content DynamoDB tests.
    static func makeLargeJSONContent() -> String {
        let base = #"{"key":"value","description":"padding-"#
        let padding = String(repeating: "x", count: 1024 * 1024 - base.count - 2)
        return base + padding + #""}"#
    }
}
