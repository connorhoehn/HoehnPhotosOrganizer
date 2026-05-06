import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct ActivityEventRepositoryTests {

    // MARK: - Helpers

    private func makeEvent(
        id: String = UUID().uuidString,
        kind: ActivityEventKind = .importBatch,
        parentEventId: String? = nil,
        photoAssetId: String? = nil,
        title: String = "Test event"
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            kind: kind,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: title,
            detail: nil,
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
    }

    // MARK: - testInsertRootEventPersists

    @Test
    func testInsertRootEventPersists() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)

        let event = makeEvent(id: "root-1", title: "Import batch started")
        try await repo.insert(event)

        let fetched = try await repo.fetchEvent(id: "root-1")
        let e = try #require(fetched, "Inserted event must be fetchable by ID")
        #expect(e.title == "Import batch started")
        #expect(e.parentEventId == nil)
    }

    // MARK: - testInsertChildEventLinksToParent

    @Test
    func testInsertChildEventLinksToParent() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)

        let root  = makeEvent(id: "parent-1", title: "Root")
        let child = makeEvent(id: "child-1", parentEventId: "parent-1", title: "Child")
        try await repo.insert(root)
        try await repo.insert(child)

        let children = try await repo.fetchChildren(of: "parent-1")
        #expect(children.count == 1, "One child must be linked to parent")
        #expect(children.first?.id == "child-1")
    }

    // MARK: - testFetchRootEventsExcludesChildren

    @Test
    func testFetchRootEventsExcludesChildren() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)

        let root  = makeEvent(id: "root-2", title: "Root event")
        let child = makeEvent(id: "child-2", parentEventId: "root-2", title: "Child event")
        try await repo.insert(root)
        try await repo.insert(child)

        let roots = try await repo.fetchRootEvents()
        #expect(roots.count == 1, "fetchRootEvents must exclude child events")
        #expect(roots.first?.id == "root-2")
    }

    // MARK: - testCascadeDeleteRemovesChildrenViaSQL

    @Test
    func testCascadeDeleteRemovesChildrenViaSQL() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)

        let root  = makeEvent(id: "root-3", title: "Root")
        let child = makeEvent(id: "child-3", parentEventId: "root-3", title: "Child")
        try await repo.insert(root)
        try await repo.insert(child)

        // Delete parent via raw SQL; ON DELETE CASCADE must remove the child row
        try await db.dbPool.write { conn in
            try conn.execute(sql: "DELETE FROM activity_events WHERE id = ?", arguments: ["root-3"])
        }

        let remaining = try await repo.fetchChildren(of: "root-3")
        #expect(remaining.isEmpty, "ON DELETE CASCADE must remove child when parent is deleted")
    }

    // MARK: - testInsertOrIgnoreIsIdempotent

    @Test
    func testInsertOrIgnoreIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)

        let event = makeEvent(id: "idempotent-1", title: "First write")
        try await repo.insertOrIgnore(event)
        try await repo.insertOrIgnore(event)  // must be a no-op

        let roots = try await repo.fetchRootEvents()
        #expect(roots.count == 1, "insertOrIgnore must not create duplicates")
    }

    // MARK: - testFetchEventsForPhotoReturnsAll

    @Test
    func testFetchEventsForPhotoReturnsAll() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "photo.jpg", role: .original,
                                   filePath: "/photo.jpg", fileSize: 0)
        try await photoRepo.upsert(asset)

        let e1 = makeEvent(id: "photo-ev-1", photoAssetId: asset.id, title: "Event 1")
        let e2 = makeEvent(id: "photo-ev-2", photoAssetId: asset.id, title: "Event 2")
        try await repo.insert(e1)
        try await repo.insert(e2)

        let events = try await repo.fetchEventsForPhoto(asset.id)
        #expect(events.count == 2, "Both events for the photo must be returned")
    }
}
