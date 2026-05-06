import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class PersonRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: PersonRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = PersonRepository(db: db)
    }

    // MARK: - upsert + fetchAll

    func testUpsertAndFetchAllReturnsSortedByName() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        let zara = PersonIdentity(id: "z", name: "Zara",  coverFaceEmbeddingId: nil, createdAt: now)
        let alice = PersonIdentity(id: "a", name: "Alice", coverFaceEmbeddingId: nil, createdAt: now)
        let bob  = PersonIdentity(id: "b", name: "Bob",   coverFaceEmbeddingId: nil, createdAt: now)

        try await repo.upsert(zara)
        try await repo.upsert(alice)
        try await repo.upsert(bob)

        let all = try await repo.fetchAll()
        XCTAssertEqual(all.map(\.name), ["Alice", "Bob", "Zara"], "fetchAll must be sorted alphabetically by name")
    }

    // MARK: - findOrCreate idempotency

    func testFindOrCreateIsIdempotent() async throws {
        let first  = try await repo.findOrCreate(name: "Dana")
        let second = try await repo.findOrCreate(name: "Dana")

        XCTAssertEqual(first.id, second.id, "findOrCreate must return the same record on repeated calls")
        let all = try await repo.fetchAll()
        XCTAssertEqual(all.count, 1, "findOrCreate must not create duplicate rows")
    }

    // MARK: - rename

    func testRenameChangesName() async throws {
        let person = try await repo.findOrCreate(name: "Eve")
        try await repo.rename(personId: person.id, to: "Evelyn")

        let found = try await repo.findByName("Evelyn")
        XCTAssertNotNil(found, "Renamed person must be findable by new name")
        XCTAssertEqual(found?.id, person.id)

        let old = try await repo.findByName("Eve")
        XCTAssertNil(old, "Old name must not match after rename")
    }

    // MARK: - delete

    func testDeleteRemovesPerson() async throws {
        let person = try await repo.findOrCreate(name: "Frank")
        try await repo.delete(person.id)

        let all = try await repo.fetchAll()
        XCTAssertTrue(all.isEmpty, "fetchAll must be empty after deleting the only person")
    }

    // MARK: - fetchPeopleWithPhotoCounts JOIN

    func testFetchPeopleWithPhotoCountsReturnsCorrectCounts() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        let grace = try await repo.findOrCreate(name: "Grace")
        let henry = try await repo.findOrCreate(name: "Henry")

        // Insert two photo_assets rows
        try await db.dbPool.write { db in
            for (idx, pid) in ["photo-g1", "photo-g2", "photo-h1"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO photo_assets
                        (id, canonical_name, role, file_path, file_size,
                         processing_state, curation_state, sync_state, created_at, updated_at)
                    VALUES (?, ?, 'original', ?, 1000, 'indexed', 'needs_review', 'local_only', ?, ?)
                """, arguments: [pid, "\(idx).NEF", "/tmp/\(idx).NEF", now, now])
            }

            // Grace is on 2 photos; Henry is on 1
            for (feId, photoId, personId) in [
                ("fe-g1", "photo-g1", grace.id),
                ("fe-g2", "photo-g2", grace.id),
                ("fe-h1", "photo-h1", henry.id)
            ] {
                try db.execute(sql: """
                    INSERT INTO face_embeddings
                        (id, photo_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
                         feature_data, created_at, person_id)
                    VALUES (?, ?, 0, 0.1, 0.1, 0.2, 0.3, X'', ?, ?)
                """, arguments: [feId, photoId, now, personId])
            }
        }

        let counts = try await repo.fetchPeopleWithPhotoCounts()
        XCTAssertEqual(counts.count, 2, "Both labeled people must appear")
        // Ordered by count descending → Grace first
        XCTAssertEqual(counts[0].name, "Grace")
        XCTAssertEqual(counts[0].count, 2)
        XCTAssertEqual(counts[1].name, "Henry")
        XCTAssertEqual(counts[1].count, 1)
    }
}
