//
//  SyncDeltaQueueTests.swift
//  HoehnPhotosCoreTests
//
//  Tests for `PeopleSyncDelta` — the people/face mutation queue payload.
//  Covers:
//    - Codable roundtrip across all 6 cases
//    - `.id` stability (de-dup key) and uniqueness per-target
//    - Factory helpers auto-populate ISO8601 timestamps
//    - `createPerson` factory generates a UUID
//

import XCTest
@testable import HoehnPhotosCore

final class SyncDeltaQueueTests: XCTestCase {

    // MARK: - Codable roundtrip

    func testCreatePersonRoundtrip() throws {
        let original = PeopleSyncDelta.createPerson(
            id: "person-1",
            name: "Alice",
            coverFaceId: "face-42",
            createdAt: "2026-04-18T12:00:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "createPerson:person-1")
        if case .createPerson(let id, let name, let cover, let createdAt) = decoded {
            XCTAssertEqual(id, "person-1")
            XCTAssertEqual(name, "Alice")
            XCTAssertEqual(cover, "face-42")
            XCTAssertEqual(createdAt, "2026-04-18T12:00:00Z")
        } else {
            XCTFail("Expected .createPerson, got \(decoded)")
        }
    }

    func testCreatePersonWithNilCoverRoundtrip() throws {
        let original = PeopleSyncDelta.createPerson(
            id: "person-2",
            name: "Bob",
            coverFaceId: nil,
            createdAt: "2026-04-18T12:00:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        if case .createPerson(_, _, let cover, _) = decoded {
            XCTAssertNil(cover)
        } else {
            XCTFail("Expected .createPerson, got \(decoded)")
        }
    }

    func testRenamePersonRoundtrip() throws {
        let original = PeopleSyncDelta.renamePerson(
            id: "person-1",
            name: "Alice R.",
            updatedAt: "2026-04-18T12:05:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "renamePerson:person-1")
    }

    func testDeletePersonRoundtrip() throws {
        let original = PeopleSyncDelta.deletePerson(
            id: "person-1",
            deletedAt: "2026-04-18T12:10:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "deletePerson:person-1")
    }

    func testMergePeopleRoundtrip() throws {
        let original = PeopleSyncDelta.mergePeople(
            sourceId: "src-1",
            targetId: "tgt-1",
            mergedAt: "2026-04-18T12:15:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "mergePeople:src-1->tgt-1")
    }

    func testAssignFaceRoundtrip() throws {
        let original = PeopleSyncDelta.assignFace(
            faceId: "face-9",
            personId: "person-1",
            labeledBy: "user",
            updatedAt: "2026-04-18T12:20:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "assignFace:face-9")
    }

    func testUnassignFaceRoundtrip() throws {
        let original = PeopleSyncDelta.unassignFace(
            faceId: "face-9",
            updatedAt: "2026-04-18T12:25:00Z"
        )
        let decoded = try roundtrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "unassignFace:face-9")
    }

    /// Array roundtrip (this is what flushPeopleDeltas actually serializes).
    func testArrayRoundtripAcrossAllCases() throws {
        let all: [PeopleSyncDelta] = [
            .createPerson(id: "p1", name: "A", coverFaceId: "f1", createdAt: "2026-04-18T12:00:00Z"),
            .renamePerson(id: "p1", name: "A2", updatedAt: "2026-04-18T12:01:00Z"),
            .deletePerson(id: "p1", deletedAt: "2026-04-18T12:02:00Z"),
            .mergePeople(sourceId: "p1", targetId: "p2", mergedAt: "2026-04-18T12:03:00Z"),
            .assignFace(faceId: "f1", personId: "p1", labeledBy: "user", updatedAt: "2026-04-18T12:04:00Z"),
            .unassignFace(faceId: "f1", updatedAt: "2026-04-18T12:05:00Z"),
        ]
        let data = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([PeopleSyncDelta].self, from: data)
        XCTAssertEqual(decoded, all)
    }

    // MARK: - .id stability / uniqueness

    func testIdIsStableAcrossTwoRenamesOfSamePerson() {
        // Two rapid renames of same person must share the same `.id`
        // so the queue de-dup in PeerSyncService collapses them.
        let r1 = PeopleSyncDelta.renamePerson(id: "person-1", name: "First")
        // Sleep a hair so the ISO timestamps differ — id must still match.
        Thread.sleep(forTimeInterval: 0.002)
        let r2 = PeopleSyncDelta.renamePerson(id: "person-1", name: "Second")
        XCTAssertEqual(r1.id, r2.id)
        XCTAssertEqual(r1.id, "renamePerson:person-1")
        XCTAssertNotEqual(r1, r2, "Timestamps/name differ — deltas should not be equal even though ids match")
    }

    func testIdDiffersForDifferentPersonTargets() {
        let a = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        let b = PeopleSyncDelta.renamePerson(id: "p2", name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testIdDiffersAcrossOperationsOnSameTarget() {
        // Same subject id but different operation → distinct queue slots.
        let rename = PeopleSyncDelta.renamePerson(id: "p1", name: "X")
        let delete = PeopleSyncDelta.deletePerson(id: "p1")
        let create = PeopleSyncDelta.createPerson(id: "p1", name: "X", coverFaceId: nil, createdAt: "t")
        XCTAssertNotEqual(rename.id, delete.id)
        XCTAssertNotEqual(delete.id, create.id)
        XCTAssertNotEqual(rename.id, create.id)
    }

    func testAssignAndUnassignShareFaceIdentitySpaceDistinctly() {
        let assign = PeopleSyncDelta.assignFace(faceId: "f1", personId: "p1")
        let unassign = PeopleSyncDelta.unassignFace(faceId: "f1")
        XCTAssertNotEqual(assign.id, unassign.id)
        XCTAssertEqual(assign.id, "assignFace:f1")
        XCTAssertEqual(unassign.id, "unassignFace:f1")
    }

    func testMergeIdEncodesDirection() {
        // merge A→B and merge B→A must not collapse to the same id.
        let ab = PeopleSyncDelta.mergePeople(source: "A", target: "B")
        let ba = PeopleSyncDelta.mergePeople(source: "B", target: "A")
        XCTAssertNotEqual(ab.id, ba.id)
    }

    // MARK: - Factory defaults

    func testCreatePersonFactoryGeneratesUUID() {
        let a = PeopleSyncDelta.createPerson(name: "Alice")
        let b = PeopleSyncDelta.createPerson(name: "Alice")
        guard case .createPerson(let idA, _, _, _) = a,
              case .createPerson(let idB, _, _, _) = b
        else {
            return XCTFail("Expected .createPerson cases")
        }
        XCTAssertNotEqual(idA, idB, "Each factory call should generate a distinct UUID")
        XCTAssertNotNil(UUID(uuidString: idA), "Generated id must be a valid UUID string (got: \(idA))")
        XCTAssertNotNil(UUID(uuidString: idB), "Generated id must be a valid UUID string (got: \(idB))")
    }

    func testCreatePersonFactoryPopulatesISO8601CreatedAt() {
        let d = PeopleSyncDelta.createPerson(name: "Alice", coverFaceId: "f1")
        guard case .createPerson(_, let name, let cover, let createdAt) = d else {
            return XCTFail("Expected .createPerson")
        }
        XCTAssertEqual(name, "Alice")
        XCTAssertEqual(cover, "f1")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: createdAt),
                        "createdAt should parse as ISO8601 (got: \(createdAt))")
    }

    func testRenamePersonFactoryPopulatesISO8601UpdatedAt() {
        let d = PeopleSyncDelta.renamePerson(id: "p1", name: "NewName")
        guard case .renamePerson(let id, let name, let updatedAt) = d else {
            return XCTFail("Expected .renamePerson")
        }
        XCTAssertEqual(id, "p1")
        XCTAssertEqual(name, "NewName")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: updatedAt),
                        "updatedAt should parse as ISO8601 (got: \(updatedAt))")
    }

    func testDeletePersonFactoryPopulatesISO8601DeletedAt() {
        let d = PeopleSyncDelta.deletePerson(id: "p1")
        guard case .deletePerson(let id, let deletedAt) = d else {
            return XCTFail("Expected .deletePerson")
        }
        XCTAssertEqual(id, "p1")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: deletedAt))
    }

    func testMergePeopleFactoryPopulatesISO8601MergedAt() {
        let d = PeopleSyncDelta.mergePeople(source: "s", target: "t")
        guard case .mergePeople(let src, let tgt, let mergedAt) = d else {
            return XCTFail("Expected .mergePeople")
        }
        XCTAssertEqual(src, "s")
        XCTAssertEqual(tgt, "t")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: mergedAt))
    }

    func testAssignFaceFactoryPopulatesISO8601UpdatedAtAndDefaultLabeledBy() {
        let d = PeopleSyncDelta.assignFace(faceId: "f1", personId: "p1")
        guard case .assignFace(let faceId, let personId, let labeledBy, let updatedAt) = d else {
            return XCTFail("Expected .assignFace")
        }
        XCTAssertEqual(faceId, "f1")
        XCTAssertEqual(personId, "p1")
        XCTAssertEqual(labeledBy, "user", "Factory default labeledBy should be 'user'")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: updatedAt))
    }

    func testAssignFaceFactoryAllowsOverridingLabeledBy() {
        let d = PeopleSyncDelta.assignFace(faceId: "f1", personId: "p1", labeledBy: "claude")
        guard case .assignFace(_, _, let labeledBy, _) = d else {
            return XCTFail("Expected .assignFace")
        }
        XCTAssertEqual(labeledBy, "claude")
    }

    func testUnassignFaceFactoryPopulatesISO8601UpdatedAt() {
        let d = PeopleSyncDelta.unassignFace(faceId: "f9")
        guard case .unassignFace(let faceId, let updatedAt) = d else {
            return XCTFail("Expected .unassignFace")
        }
        XCTAssertEqual(faceId, "f9")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: updatedAt))
    }

    // MARK: - Helpers

    private func roundtrip(_ delta: PeopleSyncDelta) throws -> PeopleSyncDelta {
        let data = try JSONEncoder().encode(delta)
        return try JSONDecoder().decode(PeopleSyncDelta.self, from: data)
    }
}
