import Testing
import GRDB
@testable import HoehnPhotosOrganizer

struct SmartCollectionTests {

    @Test
    func testSmartCollectionRuleRequestWithCurationStateEquals() async throws {
        // CUR-4: a SmartCollection with a curation_state equals rule must fetch only keeper photos
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        // Seed 3 photos with different curation states
        var keeper = PhotoAsset.new(canonicalName: "keeper.dng", role: .original, filePath: "/test", fileSize: 100)
        keeper.id = "keeper"
        keeper.curationState = CurationState.keeper.rawValue
        try await db.dbPool.write { conn in
            try keeper.insert(conn)
        }

        var archive = PhotoAsset.new(canonicalName: "archive.dng", role: .original, filePath: "/test", fileSize: 100)
        archive.id = "archive"
        archive.curationState = CurationState.archive.rawValue
        try await db.dbPool.write { conn in
            try archive.insert(conn)
        }

        var rejected = PhotoAsset.new(canonicalName: "rejected.dng", role: .original, filePath: "/test", fileSize: 100)
        rejected.id = "rejected"
        rejected.curationState = CurationState.rejected.rawValue
        try await db.dbPool.write { conn in
            try rejected.insert(conn)
        }

        // Build a rule requesting only keeper photos
        let rule = SmartCollectionRule(field: .curationState, op: .equals, value: CurationState.keeper.rawValue)
        let req = repo.request(for: [rule])

        let results = try await db.dbPool.read { conn in
            try req.fetchAll(conn)
        }

        #expect(results.count == 1)
        #expect(results.first?.id == "keeper")
    }

    @Test
    func testSmartCollectionRuleRequestWithCurationStateNotEquals() async throws {
        // CUR-4: notEquals rule must fetch all photos except the specified state
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        var keeper = PhotoAsset.new(canonicalName: "keeper.dng", role: .original, filePath: "/test", fileSize: 100)
        keeper.id = "keeper"
        keeper.curationState = CurationState.keeper.rawValue
        try await db.dbPool.write { conn in
            try keeper.insert(conn)
        }

        var archive = PhotoAsset.new(canonicalName: "archive.dng", role: .original, filePath: "/test", fileSize: 100)
        archive.id = "archive"
        archive.curationState = CurationState.archive.rawValue
        try await db.dbPool.write { conn in
            try archive.insert(conn)
        }

        var rejected = PhotoAsset.new(canonicalName: "rejected.dng", role: .original, filePath: "/test", fileSize: 100)
        rejected.id = "rejected"
        rejected.curationState = CurationState.rejected.rawValue
        try await db.dbPool.write { conn in
            try rejected.insert(conn)
        }

        // Rule: NOT rejected
        let rule = SmartCollectionRule(field: .curationState, op: .notEquals, value: CurationState.rejected.rawValue)
        let req = repo.request(for: [rule])

        let results = try await db.dbPool.read { conn in
            try req.fetchAll(conn)
        }

        #expect(results.count == 2)
        let ids = Set(results.map { $0.id })
        #expect(ids == ["keeper", "archive"])
    }

    @Test
    func testSmartCollectionRuleRequestWithEmptyRulesArray() async throws {
        // CUR-4: empty rules array must fetch all photos
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        // Seed 3 photos
        for i in 1...3 {
            var photo = PhotoAsset.new(canonicalName: "photo\(i).dng", role: .original, filePath: "/test", fileSize: 100)
            photo.id = "photo\(i)"
            try await db.dbPool.write { conn in
                try photo.insert(conn)
            }
        }

        let req = repo.request(for: [])

        let results = try await db.dbPool.read { conn in
            try req.fetchAll(conn)
        }

        #expect(results.count == 3)
    }

    @Test
    func testSmartCollectionFetchPhotosWithProcessingStateRule() async throws {
        // CUR-4: processingState rule should also work
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        var proxyReady = PhotoAsset.new(canonicalName: "proxy_ready.dng", role: .original, filePath: "/test", fileSize: 100)
        proxyReady.id = "proxy_ready"
        proxyReady.processingState = ProcessingState.proxyReady.rawValue
        try await db.dbPool.write { conn in
            try proxyReady.insert(conn)
        }

        var pending = PhotoAsset.new(canonicalName: "pending.dng", role: .original, filePath: "/test", fileSize: 100)
        pending.id = "pending"
        pending.processingState = ProcessingState.proxyPending.rawValue
        try await db.dbPool.write { conn in
            try pending.insert(conn)
        }

        let rule = SmartCollectionRule(field: .processingState, op: .equals, value: ProcessingState.proxyReady.rawValue)
        let results = try await repo.fetchPhotos(forSmartCollection: "dummy-id", rules: [rule])

        #expect(results.count == 1)
        #expect(results.first?.id == "proxy_ready")
    }

    @Test
    func testSmartCollectionFetchPhotosWithZeroMatches() async throws {
        // CUR-4: smart collection with zero matching photos should return empty array (not error)
        let db = try AppDatabase.makeInMemory()
        let repo = CollectionRepository(db: db)

        var photo = PhotoAsset.new(canonicalName: "archive.dng", role: .original, filePath: "/test", fileSize: 100)
        photo.id = "archive"
        photo.curationState = CurationState.archive.rawValue
        try await db.dbPool.write { conn in
            try photo.insert(conn)
        }

        // Ask for keeper photos (won't find any)
        let rule = SmartCollectionRule(field: .curationState, op: .equals, value: CurationState.keeper.rawValue)
        let results = try await repo.fetchPhotos(forSmartCollection: "dummy-id", rules: [rule])

        #expect(results.isEmpty)
    }
}
