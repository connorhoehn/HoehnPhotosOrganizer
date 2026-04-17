import Foundation
import GRDB

actor PersonRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func upsert(_ person: PersonIdentity) async throws {
        try await db.dbPool.write { db in
            try person.upsert(db)
        }
    }

    func fetchAll() async throws -> [PersonIdentity] {
        try await db.dbPool.read { db in
            try PersonIdentity.order(Column("name")).fetchAll(db)
        }
    }

    func findByName(_ name: String) async throws -> PersonIdentity? {
        try await db.dbPool.read { db in
            try PersonIdentity
                .filter(Column("name") == name)
                .fetchOne(db)
        }
    }

    /// Find or create a PersonIdentity with the given name.
    func findOrCreate(name: String) async throws -> PersonIdentity {
        if let existing = try await findByName(name) { return existing }
        let person = PersonIdentity(
            id: UUID().uuidString,
            name: name,
            coverFaceEmbeddingId: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try await upsert(person)
        return person
    }

    func rename(personId: String, to newName: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE person_identities SET name = ? WHERE id = ?",
                arguments: [newName, personId]
            )
        }
    }

    func delete(_ personId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: "DELETE FROM person_identities WHERE id = ?", arguments: [personId])
        }
    }

    /// Fetch all labeled people with their photo counts, ordered by count descending.
    func fetchPeopleWithPhotoCounts() async throws -> [(name: String, count: Int)] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.name, COUNT(DISTINCT fe.photo_id) as photo_count
                FROM person_identities p
                JOIN face_embeddings fe ON fe.person_id = p.id
                GROUP BY p.id
                ORDER BY photo_count DESC
                """)
            return rows.map { row in
                let name: String = row["name"]
                let count: Int = row["photo_count"]
                return (name, count)
            }
        }
    }
}
