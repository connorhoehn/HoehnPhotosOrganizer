import Testing
import GRDB
@testable import HoehnPhotosOrganizer

struct CollectionRepositoryTests {

    @Test
    func testCreateCollectionInsertsMockCollection() async throws {
        // Task 1: createCollection(name:) must insert a new Collection row with kind="manual"
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        let collection = try await repo.createCollection(name: "Test Album")

        #expect(collection.name == "Test Album")
        #expect(collection.kind == "manual")
        #expect(!collection.id.isEmpty)

        // Verify it's in the database
        let fetched = try await db.dbPool.read { conn in
            try PhotoCollection.fetchOne(conn, key: collection.id)
        }
        #expect(fetched != nil)
        #expect(fetched?.name == "Test Album")
    }

    @Test
    func testAddPhotoToCollectionCreatesMembershipRow() async throws {
        // CUR-3: addPhoto(id:to:) must insert a row into collection_members
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        // Create a test collection
        let collection = try await repo.createCollection(name: "Test")

        // Create a test photo
        var photo = PhotoAsset.new(canonicalName: "photo1.dng", role: .original, filePath: "/test", fileSize: 100)
        photo.id = "photo1"
        try await db.dbPool.write { conn in
            try photo.insert(conn)
        }

        // Add photo to collection
        try await repo.addPhoto(photoId: "photo1", toCollection: collection.id)

        // Verify membership exists
        let members = try await db.dbPool.read { conn in
            try CollectionMember
                .filter(Column("collection_id") == collection.id)
                .fetchAll(conn)
        }
        #expect(members.count == 1)
        #expect(members.first?.photoId == "photo1")
    }

    @Test
    func testRemovePhotoFromCollectionDeletesMembershipRow() async throws {
        // CUR-3: removePhoto(id:from:) must delete the matching row from collection_members
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        // Create collection and photo
        let collection = try await repo.createCollection(name: "Test")
        var photo = PhotoAsset.new(canonicalName: "photo1.dng", role: .original, filePath: "/test", fileSize: 100)
        photo.id = "photo1"
        try await db.dbPool.write { conn in
            try photo.insert(conn)
        }

        // Add then remove
        try await repo.addPhoto(photoId: "photo1", toCollection: collection.id)
        try await repo.removePhoto(photoId: "photo1", fromCollection: collection.id)

        // Verify membership is deleted
        let members = try await db.dbPool.read { conn in
            try CollectionMember
                .filter(Column("collection_id") == collection.id)
                .fetchAll(conn)
        }
        #expect(members.count == 0)
    }

    @Test
    func testFetchAllCollectionsReturnsOrderedList() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        let c1 = try await repo.createCollection(name: "B Album")
        let c2 = try await repo.createCollection(name: "A Album")

        let all = try await repo.fetchAllCollections()

        #expect(all.count == 2)
        // Should be ordered by sort_order, then name
        #expect(all[0].name == "A Album")
        #expect(all[1].name == "B Album")
    }

    @Test
    func testFetchPhotosInCollectionReturnsJoinedResults() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        let collection = try await repo.createCollection(name: "Test")

        // Create 3 photos
        for i in 1...3 {
            var photo = PhotoAsset.new(canonicalName: "photo\(i).dng", role: .original, filePath: "/test", fileSize: 100)
            photo.id = "photo\(i)"
            try await db.dbPool.write { conn in
                try photo.insert(conn)
            }
            if i <= 2 {
                try await repo.addPhoto(photoId: "photo\(i)", toCollection: collection.id)
            }
        }

        let photosInCollection = try await repo.fetchPhotos(inCollection: collection.id)

        #expect(photosInCollection.count == 2)
        #expect(photosInCollection.map { $0.id }.contains("photo1"))
        #expect(photosInCollection.map { $0.id }.contains("photo2"))
        #expect(!photosInCollection.map { $0.id }.contains("photo3"))
    }
}
