//
//  MobilePeopleRepositoryTests.swift
//  HoehnPhotosCoreTests
//
//  End-to-end tests for `MobilePeopleRepository` against a real in-memory
//  GRDB database. No mocks, no stubs.
//
//  Schema note
//  -----------
//  `AppDatabase.makeInMemory()` runs `ensureMinimalSchema` which is missing
//  the `cover_face_embedding_id` column that `MobilePeopleRepository.createPerson`
//  writes into, and sets `updated_at NOT NULL` with no default (but the repo's
//  INSERT doesn't supply a value).  To let the production code run unmodified
//  on an in-memory DB, the test helper below drops & recreates the
//  `person_identities` table with a schema that matches the macOS side
//  (includes `cover_face_embedding_id`, nullable `updated_at`). This keeps the
//  tests honest about the SQL the repo actually issues.
//

import XCTest
import GRDB
@testable import HoehnPhotosCore

final class MobilePeopleRepositoryTests: XCTestCase {

    // MARK: - Fixtures

    /// Fixed ISO timestamps so we can assert `created_at` is untouched by mutations.
    private let createdAtAlice = "2026-01-01T00:00:00Z"
    private let createdAtUnnamed = "2026-01-02T00:00:00Z"

    // MARK: - Helpers

    /// Build an in-memory AppDatabase with a schema the MobilePeopleRepository can talk to.
    /// Recreates `person_identities` with the columns the production mutations actually use.
    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try db.dbPool.write { conn in
            // Replace person_identities with the "full" shape (includes cover_face_embedding_id,
            // and makes updated_at nullable since the repo's INSERT doesn't supply it).
            try conn.execute(sql: "DROP TABLE IF EXISTS person_identities")
            try conn.execute(sql: """
                CREATE TABLE person_identities (
                    id TEXT NOT NULL PRIMARY KEY,
                    name TEXT,
                    cover_face_embedding_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT
                )
            """)
        }
        return db
    }

    /// Seeds 2 persons (one named "Alice", one with empty-string name) and several faces.
    private struct Seed {
        let db: AppDatabase
        let repo: MobilePeopleRepository
        let alicePersonId: String
        let unnamedPersonId: String
        let photoIdA: String
        let photoIdB: String
        /// Face assigned to Alice, needs_review=0
        let aliceFaceId: String
        /// Face assigned to Alice, needs_review=1 (review target)
        let aliceFaceIdPending: String
        /// Two faces assigned to the unnamed cluster
        let unnamedFaceIds: [String]
        /// Orphan face on photoA with no person assignment
        let orphanFaceId: String
    }

    private func seed() async throws -> Seed {
        let db = try makeDB()
        let repo = MobilePeopleRepository(db: db)

        let alicePersonId = "person-alice"
        let unnamedPersonId = "person-unnamed"
        let photoIdA = "photo-A"
        let photoIdB = "photo-B"
        let aliceFaceId = "face-alice-1"
        let aliceFaceIdPending = "face-alice-2"
        let unnamedFaceIds = ["face-unnamed-1", "face-unnamed-2"]
        let orphanFaceId = "face-orphan-1"

        try await db.dbPool.write { conn in
            // photo_assets rows to satisfy any photo-join queries
            for pid in [photoIdA, photoIdB] {
                try conn.execute(sql: """
                    INSERT INTO photo_assets
                        (id, canonical_name, role, file_path, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [pid, "\(pid).jpg", "master", "/tmp/\(pid).jpg",
                                 "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"])
            }

            // person_identities — one named, one empty-string name
            try conn.execute(sql: """
                INSERT INTO person_identities (id, name, cover_face_embedding_id, created_at, updated_at)
                VALUES (?, ?, NULL, ?, ?)
            """, arguments: [alicePersonId, "Alice", self.createdAtAlice, self.createdAtAlice])
            try conn.execute(sql: """
                INSERT INTO person_identities (id, name, cover_face_embedding_id, created_at, updated_at)
                VALUES (?, ?, NULL, ?, ?)
            """, arguments: [unnamedPersonId, "", self.createdAtUnnamed, self.createdAtUnnamed])

            // face_embeddings
            // 2 assigned to Alice (one needs_review, one not)
            try conn.execute(sql: """
                INSERT INTO face_embeddings
                    (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                     feature_data, created_at, person_id, labeled_by, needs_review)
                VALUES (?, ?, 0, 0.1, 0.1, 0.2, 0.2, NULL, ?, ?, 'user', 0)
            """, arguments: [aliceFaceId, photoIdA, "2026-02-01T00:00:00Z", alicePersonId])
            try conn.execute(sql: """
                INSERT INTO face_embeddings
                    (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                     feature_data, created_at, person_id, labeled_by, needs_review)
                VALUES (?, ?, 1, 0.3, 0.3, 0.2, 0.2, NULL, ?, ?, 'embedding', 1)
            """, arguments: [aliceFaceIdPending, photoIdA, "2026-02-02T00:00:00Z", alicePersonId])

            // 2 assigned to the unnamed cluster
            for (i, fid) in unnamedFaceIds.enumerated() {
                try conn.execute(sql: """
                    INSERT INTO face_embeddings
                        (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                         feature_data, created_at, person_id, labeled_by, needs_review)
                    VALUES (?, ?, ?, 0.5, 0.5, 0.2, 0.2, NULL, ?, ?, 'embedding', 0)
                """, arguments: [fid, photoIdB, i, "2026-02-0\(3+i)T00:00:00Z", unnamedPersonId])
            }

            // Orphan — no person_id, on photoA
            try conn.execute(sql: """
                INSERT INTO face_embeddings
                    (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                     feature_data, created_at, person_id, labeled_by, needs_review)
                VALUES (?, ?, 2, 0.7, 0.7, 0.1, 0.1, NULL, ?, NULL, NULL, 0)
            """, arguments: [orphanFaceId, photoIdA, "2026-02-05T00:00:00Z"])
        }

        return Seed(
            db: db, repo: repo,
            alicePersonId: alicePersonId,
            unnamedPersonId: unnamedPersonId,
            photoIdA: photoIdA, photoIdB: photoIdB,
            aliceFaceId: aliceFaceId,
            aliceFaceIdPending: aliceFaceIdPending,
            unnamedFaceIds: unnamedFaceIds,
            orphanFaceId: orphanFaceId
        )
    }

    // MARK: - fetchUnnamedClusters

    func testFetchUnnamedClustersReturnsOnlyEmptyNameCluster() async throws {
        let s = try await seed()

        let unnamed = try await s.repo.fetchUnnamedClusters()

        XCTAssertEqual(unnamed.count, 1, "Only the empty-name cluster should surface as unnamed")
        let cluster = try XCTUnwrap(unnamed.first)
        XCTAssertEqual(cluster.id, s.unnamedPersonId)
        XCTAssertEqual(cluster.faceCount, s.unnamedFaceIds.count)
        XCTAssertNotNil(cluster.representativeFaceId)
        XCTAssertNotNil(cluster.representativePhotoId)
    }

    func testFetchUnnamedClustersAlsoReturnsNullNameCluster() async throws {
        let s = try await seed()
        // Insert a cluster with NULL name (distinct from empty string).
        let nullId = "person-nullname"
        try await s.db.dbPool.write { conn in
            try conn.execute(sql: """
                INSERT INTO person_identities (id, name, cover_face_embedding_id, created_at, updated_at)
                VALUES (?, NULL, NULL, ?, ?)
            """, arguments: [nullId, "2026-01-03T00:00:00Z", "2026-01-03T00:00:00Z"])
            try conn.execute(sql: """
                INSERT INTO face_embeddings
                    (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                     feature_data, created_at, person_id, labeled_by, needs_review)
                VALUES ('face-null-1', ?, 0, 0.1, 0.1, 0.1, 0.1, NULL, ?, ?, 'embedding', 0)
            """, arguments: [s.photoIdB, "2026-02-10T00:00:00Z", nullId])
        }

        let unnamed = try await s.repo.fetchUnnamedClusters()
        let ids = Set(unnamed.map(\.id))
        XCTAssertTrue(ids.contains(s.unnamedPersonId))
        XCTAssertTrue(ids.contains(nullId))
        XCTAssertFalse(ids.contains(s.alicePersonId), "Named clusters must be excluded")
    }

    // MARK: - fetchFacesForCluster

    func testFetchFacesForClusterReturnsOnlyMembers() async throws {
        let s = try await seed()

        let aliceFaces = try await s.repo.fetchFacesForCluster(personId: s.alicePersonId)
        XCTAssertEqual(Set(aliceFaces.map(\.id)), Set([s.aliceFaceId, s.aliceFaceIdPending]))

        let unnamedFaces = try await s.repo.fetchFacesForCluster(personId: s.unnamedPersonId)
        XCTAssertEqual(Set(unnamedFaces.map(\.id)), Set(s.unnamedFaceIds))
    }

    func testFetchFacesForClusterUnknownIdReturnsEmpty() async throws {
        let s = try await seed()
        let faces = try await s.repo.fetchFacesForCluster(personId: "does-not-exist")
        XCTAssertTrue(faces.isEmpty)
    }

    // MARK: - fetchFacesNeedingReview

    func testFetchFacesNeedingReviewReturnsOnlyNeedsReview() async throws {
        let s = try await seed()
        let review = try await s.repo.fetchFacesNeedingReview()
        XCTAssertEqual(review.count, 1)
        XCTAssertEqual(review.first?.id, s.aliceFaceIdPending)
        XCTAssertTrue(review.first?.needsReview ?? false)
    }

    func testFetchFacesNeedingReviewExcludesCleanAndOrphan() async throws {
        let s = try await seed()
        let review = try await s.repo.fetchFacesNeedingReview()
        let ids = Set(review.map(\.id))
        XCTAssertFalse(ids.contains(s.aliceFaceId), "Clean assigned face must be excluded")
        XCTAssertFalse(ids.contains(s.orphanFaceId), "Orphan face (needs_review=0) must be excluded")
        XCTAssertFalse(ids.contains(where: s.unnamedFaceIds.contains), "Non-review faces excluded")
    }

    // MARK: - fetchFacesForPhoto

    func testFetchFacesForPhotoReturnsFacesWithNamesWhereAssigned() async throws {
        let s = try await seed()

        let faces = try await s.repo.fetchFacesForPhoto(photoId: s.photoIdA)

        XCTAssertEqual(faces.count, 3, "photoA has 2 Alice faces + 1 orphan")
        // Alice-assigned faces should have the name joined in.
        for aliceId in [s.aliceFaceId, s.aliceFaceIdPending] {
            let f = try XCTUnwrap(faces.first { $0.id == aliceId })
            XCTAssertEqual(f.personId, s.alicePersonId)
            XCTAssertEqual(f.personName, "Alice")
        }
        // Orphan should have nil personId and nil personName.
        let orphan = try XCTUnwrap(faces.first { $0.id == s.orphanFaceId })
        XCTAssertNil(orphan.personId)
        XCTAssertNil(orphan.personName)
        XCTAssertFalse(orphan.needsReview)

        // needs_review bool mapping sanity
        let pending = try XCTUnwrap(faces.first { $0.id == s.aliceFaceIdPending })
        XCTAssertTrue(pending.needsReview)
    }

    func testFetchFacesForPhotoReturnsOrderedByFaceIndex() async throws {
        let s = try await seed()
        let faces = try await s.repo.fetchFacesForPhoto(photoId: s.photoIdA)
        let indices = faces.compactMap { face -> Int? in
            // We didn't expose face_index on PhotoFace; verify order via bbox_x which
            // was assigned to distinct values per index in the seed. Alice0=0.1, Alice1=0.3, Orphan=0.7.
            return Int(face.bboxX * 10)
        }
        XCTAssertEqual(indices, indices.sorted(), "Faces must be returned in face_index ascending order")
    }

    func testFetchFacesForPhotoEmptyForUnknownPhoto() async throws {
        let s = try await seed()
        let faces = try await s.repo.fetchFacesForPhoto(photoId: "nope")
        XCTAssertTrue(faces.isEmpty)
    }

    // MARK: - renamePerson

    func testRenamePersonUpdatesNameWithoutTouchingCreatedAt() async throws {
        let s = try await seed()

        let beforeCreatedAt = try await s.db.dbPool.read { conn -> String in
            try String.fetchOne(conn, sql: "SELECT created_at FROM person_identities WHERE id = ?",
                                arguments: [s.alicePersonId]) ?? ""
        }
        XCTAssertEqual(beforeCreatedAt, self.createdAtAlice)

        try await s.repo.renamePerson(id: s.alicePersonId, name: "Alicia")

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: "SELECT name, created_at FROM person_identities WHERE id = ?",
                                 arguments: [s.alicePersonId])
            )
            XCTAssertEqual(row["name"] as String?, "Alicia")
            XCTAssertEqual(row["created_at"] as String?, self.createdAtAlice,
                           "renamePerson must not touch created_at")
        }
    }

    // MARK: - createPerson

    func testCreatePersonInsertsRow() async throws {
        let s = try await seed()
        let newId = "person-new"
        let createdAt = "2026-03-01T00:00:00Z"

        try await s.repo.createPerson(id: newId, name: "Carol", coverFaceId: "face-x", createdAt: createdAt)

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: "SELECT name, cover_face_embedding_id, created_at FROM person_identities WHERE id = ?",
                                 arguments: [newId])
            )
            XCTAssertEqual(row["name"] as String?, "Carol")
            XCTAssertEqual(row["cover_face_embedding_id"] as String?, "face-x")
            XCTAssertEqual(row["created_at"] as String?, createdAt)
        }
    }

    func testCreatePersonWithSameIdIsNoOp() async throws {
        let s = try await seed()
        let newId = "person-new"

        try await s.repo.createPerson(id: newId, name: "Carol", coverFaceId: nil,
                                      createdAt: "2026-03-01T00:00:00Z")
        // Second call with same id — INSERT OR IGNORE should keep the original row intact.
        try await s.repo.createPerson(id: newId, name: "DIFFERENT", coverFaceId: "face-other",
                                      createdAt: "2999-01-01T00:00:00Z")

        try await s.db.dbPool.read { conn in
            let count = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM person_identities WHERE id = ?",
                                         arguments: [newId]) ?? 0
            XCTAssertEqual(count, 1)

            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: "SELECT name, cover_face_embedding_id, created_at FROM person_identities WHERE id = ?",
                                 arguments: [newId])
            )
            XCTAssertEqual(row["name"] as String?, "Carol", "INSERT OR IGNORE must leave original name")
            XCTAssertNil(row["cover_face_embedding_id"] as String?, "INSERT OR IGNORE must not overwrite cover id")
            XCTAssertEqual(row["created_at"] as String?, "2026-03-01T00:00:00Z")
        }
    }

    // MARK: - deletePerson

    func testDeletePersonNullsOutFaceAssignmentsThenDeletesIdentity() async throws {
        let s = try await seed()

        try await s.repo.deletePerson(id: s.alicePersonId)

        try await s.db.dbPool.read { conn in
            // Identity row is gone
            let cnt = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM person_identities WHERE id = ?",
                                       arguments: [s.alicePersonId]) ?? -1
            XCTAssertEqual(cnt, 0)

            // Faces formerly on Alice are nulled (person_id + labeled_by) but still exist
            for fid in [s.aliceFaceId, s.aliceFaceIdPending] {
                let row = try XCTUnwrap(
                    try Row.fetchOne(conn, sql: "SELECT person_id, labeled_by FROM face_embeddings WHERE id = ?",
                                     arguments: [fid])
                )
                XCTAssertNil(row["person_id"] as String?)
                XCTAssertNil(row["labeled_by"] as String?)
            }

            // Unrelated faces on the unnamed cluster are untouched
            for fid in s.unnamedFaceIds {
                let row = try XCTUnwrap(
                    try Row.fetchOne(conn, sql: "SELECT person_id FROM face_embeddings WHERE id = ?",
                                     arguments: [fid])
                )
                XCTAssertEqual(row["person_id"] as String?, s.unnamedPersonId)
            }
        }
    }

    func testDeletePersonUnknownIdIsNoOp() async throws {
        let s = try await seed()
        // Should not throw.
        try await s.repo.deletePerson(id: "nobody")

        try await s.db.dbPool.read { conn in
            // Both original identities remain.
            let cnt = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM person_identities") ?? 0
            XCTAssertEqual(cnt, 2)
        }
    }

    // MARK: - mergePeople

    func testMergePeopleReassignsFacesAndDeletesSource() async throws {
        let s = try await seed()

        try await s.repo.mergePeople(sourceId: s.unnamedPersonId, targetId: s.alicePersonId)

        try await s.db.dbPool.read { conn in
            // Source identity removed
            let srcCnt = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM person_identities WHERE id = ?",
                                          arguments: [s.unnamedPersonId]) ?? -1
            XCTAssertEqual(srcCnt, 0)

            // Target identity remains
            let tgtCnt = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM person_identities WHERE id = ?",
                                          arguments: [s.alicePersonId]) ?? -1
            XCTAssertEqual(tgtCnt, 1)

            // All source faces now assigned to target
            for fid in s.unnamedFaceIds {
                let pid = try String.fetchOne(conn, sql: "SELECT person_id FROM face_embeddings WHERE id = ?",
                                              arguments: [fid])
                XCTAssertEqual(pid, s.alicePersonId)
            }

            // Pre-existing Alice faces still on Alice
            for fid in [s.aliceFaceId, s.aliceFaceIdPending] {
                let pid = try String.fetchOne(conn, sql: "SELECT person_id FROM face_embeddings WHERE id = ?",
                                              arguments: [fid])
                XCTAssertEqual(pid, s.alicePersonId)
            }

            // Orphan face unaffected
            let orphanPid = try String.fetchOne(conn, sql: "SELECT person_id FROM face_embeddings WHERE id = ?",
                                                arguments: [s.orphanFaceId])
            XCTAssertNil(orphanPid)
        }
    }

    // MARK: - assignFace

    func testAssignFaceUpdatesPersonIdLabeledByAndClearsNeedsReview() async throws {
        let s = try await seed()

        try await s.repo.assignFace(faceId: s.aliceFaceIdPending, personId: s.alicePersonId, labeledBy: "user")

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: """
                    SELECT person_id, labeled_by, needs_review FROM face_embeddings WHERE id = ?
                """, arguments: [s.aliceFaceIdPending])
            )
            XCTAssertEqual(row["person_id"] as String?, s.alicePersonId)
            XCTAssertEqual(row["labeled_by"] as String?, "user")
            // Stored as 0/1 int; compare against 0.
            XCTAssertEqual(row["needs_review"] as Int?, 0)
        }
    }

    func testAssignFaceDefaultLabeledByIsUser() async throws {
        let s = try await seed()
        // orphan has labeled_by = NULL; default should set it to "user".
        try await s.repo.assignFace(faceId: s.orphanFaceId, personId: s.alicePersonId)

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: "SELECT person_id, labeled_by, needs_review FROM face_embeddings WHERE id = ?",
                                 arguments: [s.orphanFaceId])
            )
            XCTAssertEqual(row["person_id"] as String?, s.alicePersonId)
            XCTAssertEqual(row["labeled_by"] as String?, "user")
            XCTAssertEqual(row["needs_review"] as Int?, 0)
        }
    }

    func testAssignFaceHonorsCustomLabeledBy() async throws {
        let s = try await seed()
        try await s.repo.assignFace(faceId: s.orphanFaceId, personId: s.alicePersonId, labeledBy: "claude")

        try await s.db.dbPool.read { conn in
            let labeledBy = try String.fetchOne(conn, sql: "SELECT labeled_by FROM face_embeddings WHERE id = ?",
                                                arguments: [s.orphanFaceId])
            XCTAssertEqual(labeledBy, "claude")
        }
    }

    // MARK: - unassignFace

    func testUnassignFaceNullsColumnsAndClearsNeedsReview() async throws {
        let s = try await seed()

        try await s.repo.unassignFace(faceId: s.aliceFaceIdPending)

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: """
                    SELECT person_id, labeled_by, needs_review FROM face_embeddings WHERE id = ?
                """, arguments: [s.aliceFaceIdPending])
            )
            XCTAssertNil(row["person_id"] as String?)
            XCTAssertNil(row["labeled_by"] as String?)
            XCTAssertEqual(row["needs_review"] as Int?, 0)
        }
    }

    func testUnassignFaceOnAlreadyUnassignedFaceIsNoOp() async throws {
        let s = try await seed()

        // orphan is already unassigned — should not error, should leave nulls in place.
        try await s.repo.unassignFace(faceId: s.orphanFaceId)

        try await s.db.dbPool.read { conn in
            let row = try XCTUnwrap(
                try Row.fetchOne(conn, sql: "SELECT person_id, labeled_by, needs_review FROM face_embeddings WHERE id = ?",
                                 arguments: [s.orphanFaceId])
            )
            XCTAssertNil(row["person_id"] as String?)
            XCTAssertNil(row["labeled_by"] as String?)
            XCTAssertEqual(row["needs_review"] as Int?, 0)
        }
    }
}
