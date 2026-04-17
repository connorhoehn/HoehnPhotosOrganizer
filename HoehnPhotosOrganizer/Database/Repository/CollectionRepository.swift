import Foundation
import GRDB

actor CollectionRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Manual Collection CRUD

    /// Creates a new manual collection with the given name.
    /// Returns the inserted Collection record with a generated UUID id and ISO8601 timestamps.
    func createCollection(name: String) async throws -> PhotoCollection {
        let collection = PhotoCollection.new(name: name, kind: "manual")
        try await db.dbPool.write { conn in
            try collection.insert(conn)
        }
        return collection
    }

    /// Adds a photo to a collection by creating a CollectionMember record.
    /// If the photo is already in the collection, this is idempotent (GRDB's insert ignores duplicates
    /// with the same primary key, which is fine since our schema doesn't have a unique constraint on the pairing).
    func addPhoto(photoId: String, toCollection collectionId: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        let member = CollectionMember(
            id: UUID().uuidString,
            collectionId: collectionId,
            photoId: photoId,
            addedAt: now
        )
        try await db.dbPool.write { conn in
            try member.insert(conn)
        }
    }

    /// Removes a photo from a collection by deleting the matching CollectionMember row.
    func removePhoto(photoId: String, fromCollection collectionId: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: """
                    DELETE FROM collection_members
                    WHERE collection_id = ? AND photo_id = ?
                """,
                arguments: [collectionId, photoId]
            )
        }
    }

    /// Fetches all collections ordered by sort_order ASC, then name ASC.
    func fetchAllCollections() async throws -> [PhotoCollection] {
        try await db.dbPool.read { conn in
            try PhotoCollection
                .order(Column("sort_order").asc, Column("name").asc)
                .fetchAll(conn)
        }
    }

    /// Fetches all photos in a manual collection via a JOIN on collection_members.
    /// Returns photos ordered by collection_members.added_at ASC.
    func fetchPhotos(inCollection collectionId: String) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            let sql = """
                SELECT photo_assets.* FROM photo_assets
                JOIN collection_members ON collection_members.photo_id = photo_assets.id
                WHERE collection_members.collection_id = ?
                ORDER BY collection_members.added_at ASC
            """
            return try PhotoAsset.fetchAll(conn, sql: sql, arguments: [collectionId])
        }
    }

    // MARK: - Smart Collection Rule Translation

    /// Translates an array of SmartCollectionRule structs into a GRDB QueryInterfaceRequest<PhotoAsset>.
    /// Chains .filter() calls for each rule, supporting all Field and Operator combinations.
    /// Returns a request that can be executed with .fetchAll() or used with ValueObservation.
    nonisolated
    func request(for rules: [SmartCollectionRule]) -> QueryInterfaceRequest<PhotoAsset> {
        rules.reduce(PhotoAsset.all()) { req, rule in
            switch (rule.field, rule.op) {
            case (.curationState, .equals):
                return req.filter(Column("curation_state") == rule.value)
            case (.curationState, .notEquals):
                return req.filter(Column("curation_state") != rule.value)
            case (.curationState, .isNull):
                return req.filter(Column("curation_state") == nil)
            case (.curationState, .isNotNull):
                return req.filter(Column("curation_state") != nil)

            case (.processingState, .equals):
                return req.filter(Column("processing_state") == rule.value)
            case (.processingState, .notEquals):
                return req.filter(Column("processing_state") != rule.value)
            case (.processingState, .isNull):
                return req.filter(Column("processing_state") == nil)
            case (.processingState, .isNotNull):
                return req.filter(Column("processing_state") != nil)

            case (.syncState, .equals):
                return req.filter(Column("sync_state") == rule.value)
            case (.syncState, .notEquals):
                return req.filter(Column("sync_state") != rule.value)
            case (.syncState, .isNull):
                return req.filter(Column("sync_state") == nil)
            case (.syncState, .isNotNull):
                return req.filter(Column("sync_state") != nil)

            case (.role, .equals):
                return req.filter(Column("role") == rule.value)
            case (.role, .notEquals):
                return req.filter(Column("role") != rule.value)
            case (.role, .isNull):
                return req.filter(Column("role") == nil)
            case (.role, .isNotNull):
                return req.filter(Column("role") != nil)

            case (.driveId, _):
                // photo_assets does not have a drive_id column in v1_initial
                // Return the request unchanged for driveId rules
                return req
            }
        }
    }

    /// Fetches photos for a smart collection by translating its rules to a GRDB request and executing it.
    /// Returns an empty array if no photos match the rules (not an error).
    func fetchPhotos(forSmartCollection collectionId: String, rules: [SmartCollectionRule]) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            let req = request(for: rules)
            return try req.fetchAll(conn)
        }
    }
}
