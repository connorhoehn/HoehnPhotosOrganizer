import XCTest
@testable import HoehnPhotosOrganizer
import GRDB

final class ThreadRepositoryTests: XCTestCase {

    private var db: AppDatabase!
    private var repo: ThreadRepository!
    private var testPhotoId: String = ""

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = ThreadRepository(db: db)

        // Insert a real PhotoAsset row so the FK on thread_entries.thread_root_id is satisfied.
        var photo = PhotoAsset.new(
            canonicalName: "test_photo_\(UUID().uuidString).jpg",
            role: .original,
            filePath: "/tmp/test_photo.jpg",
            fileSize: 1_024
        )
        try await db.dbPool.write { try photo.insert($0) }
        testPhotoId = photo.id
    }

    override func tearDown() async throws {
        repo = nil
        db = nil
        testPhotoId = ""
    }

    // MARK: - Tests

    /// Adding 3 entries should produce entries with sequenceNumbers 1, 2, 3 in ascending order.
    func testFetchThreadForPhotoReturnsOrderedEntries() async throws {
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{\"text\":\"first\"}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhotoId, kind: "ai_turn",   contentJson: "{\"text\":\"second\"}", authoredBy: "ai")
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{\"text\":\"third\"}", authoredBy: "user")

        let entries = try await repo.thread(for: testPhotoId)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].sequenceNumber, 1)
        XCTAssertEqual(entries[1].sequenceNumber, 2)
        XCTAssertEqual(entries[2].sequenceNumber, 3)
    }

    /// Each successive addEntry call must produce a sequence number one greater than the previous.
    func testAddEntryIncrementsSequenceNumber() async throws {
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhotoId, kind: "ai_turn",   contentJson: "{}", authoredBy: "ai")

        let entries = try await repo.thread(for: testPhotoId)

        XCTAssertEqual(entries.count, 3)
        let seqNums = entries.map(\.sequenceNumber)
        XCTAssertEqual(seqNums, [1, 2, 3], "Sequence numbers must be 1→2→3 in insertion order")
    }

    /// thread(for:) must return entries sorted ascending by sequence_number (chronological order).
    func testThreadEntriesAreSortedByTimestamp() async throws {
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{\"t\":\"a\"}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{\"t\":\"b\"}", authoredBy: "user")

        let entries = try await repo.thread(for: testPhotoId)

        XCTAssertEqual(entries.count, 2)
        XCTAssertLessThan(entries[0].sequenceNumber, entries[1].sequenceNumber,
                          "Entries must be returned in ascending chronological (sequence) order")
    }

    /// deleteEntry must remove only the targeted entry from the thread.
    func testDeleteEntryRemovesFromThread() async throws {
        try await repo.addEntry(photoId: testPhotoId, kind: "text_note", contentJson: "{}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhotoId, kind: "ai_turn",   contentJson: "{}", authoredBy: "ai")

        let before = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(before.count, 2)

        let idToDelete = before[0].id
        try await repo.deleteEntry(id: idToDelete)

        let after = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(after.count, 1)
        XCTAssertNil(after.first(where: { $0.id == idToDelete }),
                     "Deleted entry must not appear in subsequent fetch")
    }

    /// threadStream must emit at least one value (the current snapshot) when first subscribed.
    func testThreadRepositoryObservesChanges() async throws {
        let stream = await repo.threadStream(for: testPhotoId)

        var emittedValues: [[ThreadEntry]] = []
        let expectation = XCTestExpectation(description: "stream emits at least one value")

        let task = Task {
            for try await entries in stream {
                emittedValues.append(entries)
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()

        XCTAssertFalse(emittedValues.isEmpty, "threadStream must emit at least one value")
    }
}
