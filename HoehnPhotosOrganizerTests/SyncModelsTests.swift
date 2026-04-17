// SyncModelsTests.swift
// HoehnPhotosOrganizerTests
//
// Tests for SyncModels.swift cloud sync type contracts.
// Covers: SyncThreadEntry JSON round-trip, SyncStatus Codable persistence,
// and LastEditWinsConflictRule deterministic behavior.
//
// Plan: 04-01, Task 1 (TDD verification)
// Requirements: SYNC-6, SYNC-7

import XCTest
@testable import HoehnPhotosOrganizer

final class SyncModelsTests: XCTestCase {

    // MARK: - SyncThreadEntry

    /// SyncThreadEntry round-trips through JSON without data loss.
    /// Verifies all fields (threadRootId, entryId, timestamp, type, content, syncedAt)
    /// survive encode → decode.
    func test_syncThreadEntry_jsonRoundTrip() throws {
        let original = SyncThreadEntry(
            threadRootId: "IMG_1234.CR3",
            entryId: "B8F2A3D1-1234-5678-ABCD-EF0123456789",
            timestamp: 1710595200,
            type: .note,
            content: "{\"text\":\"First test print\"}",
            syncedAt: 1710595500
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SyncThreadEntry.self, from: data)

        XCTAssertEqual(decoded.threadRootId, original.threadRootId)
        XCTAssertEqual(decoded.entryId, original.entryId)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.syncedAt, original.syncedAt)
    }

    /// SyncThreadEntry with nil syncedAt (local-only) serializes and deserializes correctly.
    func test_syncThreadEntry_nilSyncedAt_roundTrip() throws {
        let entry = SyncThreadEntry(
            threadRootId: "IMG_5678.CR3",
            entryId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            timestamp: 1710600000,
            type: .printAttempt,
            content: "{\"printType\":\"inkjet_color\"}",
            syncedAt: nil
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SyncThreadEntry.self, from: data)
        XCTAssertNil(decoded.syncedAt)
    }

    /// EntryType raw values match DynamoDB and API conventions.
    func test_syncThreadEntry_entryType_rawValues() {
        XCTAssertEqual(SyncThreadEntry.EntryType.note.rawValue, "note")
        XCTAssertEqual(SyncThreadEntry.EntryType.aiTurn.rawValue, "ai_turn")
        XCTAssertEqual(SyncThreadEntry.EntryType.printAttempt.rawValue, "print_attempt")
    }

    /// SyncThreadEntry.id matches entryId (Identifiable conformance).
    func test_syncThreadEntry_identifiable() {
        let entry = SyncThreadEntry(
            threadRootId: "IMG_001.DNG",
            entryId: "UNIQUE-UUID-HERE",
            timestamp: 1000,
            type: .aiTurn,
            content: "{}",
            syncedAt: nil
        )
        XCTAssertEqual(entry.id, entry.entryId)
    }

    // MARK: - SyncStatus

    /// SyncStatus.localOnly encodes and decodes correctly.
    func test_syncStatus_localOnly_codable() throws {
        let status = SyncStatus.localOnly
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    /// SyncStatus.syncing(progress:) round-trips through JSON preserving progress value.
    func test_syncStatus_syncing_codable() throws {
        let status = SyncStatus.syncing(progress: 0.75)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    /// SyncStatus.synced(timestamp:) preserves timestamp through JSON encoding.
    func test_syncStatus_synced_codable() throws {
        // Use a rounded epoch second for reliable equality comparison.
        let date = Date(timeIntervalSince1970: 1710595200)
        let status = SyncStatus.synced(timestamp: date)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    /// SyncStatus.error(reason:) round-trips through JSON preserving error reason.
    func test_syncStatus_error_codable() throws {
        let status = SyncStatus.error(reason: "Network timeout")
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    // MARK: - ConflictRule

    /// LastEditWinsConflictRule returns the remote entry when remote.timestamp > local.timestamp.
    func test_lastEditWins_remote_wins_when_later_timestamp() {
        let local = makeSyncThreadEntry(entryId: "local-id", timestamp: 1000)
        let remote = makeSyncThreadEntry(entryId: "remote-id", timestamp: 2000)

        let rule = LastEditWinsConflictRule()
        let resolution = rule.applyRule(local: local, remote: remote)

        switch resolution {
        case .keep(let winner):
            XCTAssertEqual(winner.entryId, "remote-id", "Remote entry (T2000) should win over local (T1000)")
        case .userChoice:
            XCTFail("LastEditWinsConflictRule should not return userChoice")
        }
    }

    /// LastEditWinsConflictRule returns local entry when local.timestamp > remote.timestamp.
    func test_lastEditWins_local_wins_when_later_timestamp() {
        let local = makeSyncThreadEntry(entryId: "local-id", timestamp: 3000)
        let remote = makeSyncThreadEntry(entryId: "remote-id", timestamp: 1500)

        let rule = LastEditWinsConflictRule()
        let resolution = rule.applyRule(local: local, remote: remote)

        switch resolution {
        case .keep(let winner):
            XCTAssertEqual(winner.entryId, "local-id", "Local entry (T3000) should win over remote (T1500)")
        case .userChoice:
            XCTFail("LastEditWinsConflictRule should not return userChoice")
        }
    }

    /// LastEditWinsConflictRule breaks ties by lexicographic entryId comparison (deterministic).
    func test_lastEditWins_tie_broken_by_entryId_lexicographic() {
        // "zzz-id" > "aaa-id" lexicographically
        let local = makeSyncThreadEntry(entryId: "zzz-id", timestamp: 5000)
        let remote = makeSyncThreadEntry(entryId: "aaa-id", timestamp: 5000)

        let rule = LastEditWinsConflictRule()
        let resolution = rule.applyRule(local: local, remote: remote)

        switch resolution {
        case .keep(let winner):
            XCTAssertEqual(winner.entryId, "zzz-id", "Tie broken by entryId: 'zzz-id' > 'aaa-id'")
        case .userChoice:
            XCTFail("LastEditWinsConflictRule should not return userChoice on tie")
        }
    }

    /// UserChoiceConflictRule always returns userChoice regardless of timestamps.
    func test_userChoiceConflictRule_always_asks_user() {
        let local = makeSyncThreadEntry(entryId: "local", timestamp: 100)
        let remote = makeSyncThreadEntry(entryId: "remote", timestamp: 200)

        let rule = UserChoiceConflictRule()
        let resolution = rule.applyRule(local: local, remote: remote)

        switch resolution {
        case .userChoice(let l, let r, _):
            XCTAssertEqual(l.entryId, "local")
            XCTAssertEqual(r.entryId, "remote")
        case .keep:
            XCTFail("UserChoiceConflictRule should always return userChoice")
        }
    }

    // MARK: - SyncPayload

    /// SyncPayload with binary content (proxy) encodes/decodes correctly.
    func test_syncPayload_binaryContent_roundTrip() throws {
        let testData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let payload = SyncPayload(
            operation: .upload,
            assetType: .proxy,
            canonicalId: "IMG_9876.ARW",
            content: testData,
            jsonContent: nil,
            timestamp: 1710595200,
            checksum: "abc123def456"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)

        XCTAssertEqual(decoded.operation, .upload)
        XCTAssertEqual(decoded.assetType, .proxy)
        XCTAssertEqual(decoded.canonicalId, "IMG_9876.ARW")
        XCTAssertEqual(decoded.content, testData)
        XCTAssertEqual(decoded.checksum, "abc123def456")
    }

    /// SyncPayload with JSON content (thread entry) encodes/decodes correctly.
    func test_syncPayload_jsonContent_roundTrip() throws {
        let payload = SyncPayload(
            operation: .upload,
            assetType: .thread,
            canonicalId: "IMG_0001.CR3",
            content: nil,
            jsonContent: "{\"text\":\"Good print\"}",
            timestamp: 1710600000,
            checksum: "sha256hexdigest"
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SyncPayload.self, from: data)

        XCTAssertNil(decoded.content)
        XCTAssertEqual(decoded.jsonContent, "{\"text\":\"Good print\"}")
    }

    // MARK: - AssetType raw values

    /// AssetType raw values match S3 prefix conventions from config.json.
    func test_assetType_rawValues() {
        XCTAssertEqual(AssetType.proxy.rawValue, "proxy")
        XCTAssertEqual(AssetType.thread.rawValue, "thread")
        XCTAssertEqual(AssetType.print.rawValue, "print")
        XCTAssertEqual(AssetType.curve.rawValue, "curve")
    }

    // MARK: - SyncPrintType raw values

    /// SyncPrintType raw values match PrintType in PrintType.swift conventions.
    func test_syncPrintType_rawValues() {
        XCTAssertEqual(SyncPrintType.inkjetColor.rawValue, "inkjet_color")
        XCTAssertEqual(SyncPrintType.inkjetBW.rawValue, "inkjet_bw")
        XCTAssertEqual(SyncPrintType.silverGelatin.rawValue, "silver_gelatin")
        XCTAssertEqual(SyncPrintType.platinumPalladium.rawValue, "platinum_palladium")
        XCTAssertEqual(SyncPrintType.cyanotype.rawValue, "cyanotype")
        XCTAssertEqual(SyncPrintType.digitalNegative.rawValue, "digital_negative")
    }

    // MARK: - Helpers

    private func makeSyncThreadEntry(entryId: String, timestamp: Int64) -> SyncThreadEntry {
        SyncThreadEntry(
            threadRootId: "IMG_0001.CR3",
            entryId: entryId,
            timestamp: timestamp,
            type: .note,
            content: "{}",
            syncedAt: nil
        )
    }
}
