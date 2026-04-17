import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class PhotoThreadViewTests: XCTestCase {

    // MARK: - Test Setup

    private var db: AppDatabase!
    private var repo: ThreadRepository!
    private var testPhotoId: String = ""

    override func setUp() async throws {
        try await super.setUp()
        db = try AppDatabase.makeInMemory()
        repo = ThreadRepository(db: db)

        // Insert a PhotoAsset so the thread_entries FK constraint is satisfied.
        var photo = PhotoAsset.new(
            canonicalName: "photo_thread_view_\(UUID().uuidString).jpg",
            role: .original,
            filePath: "/tmp/test_thread_view.jpg",
            fileSize: 1024
        )
        try await db.dbPool.write { try photo.insert($0) }
        testPhotoId = photo.id
    }

    override func tearDown() async throws {
        db = nil
        repo = nil
        testPhotoId = ""
        try await super.tearDown()
    }

    // MARK: - Tests

    /// ThreadDetailView renders all entries. Verify via repository round-trip.
    func testThreadViewDisplaysAllEntries() async throws {
        let items: [(kind: String, author: String)] = [
            ("text_note", "user"),
            ("ai_turn",   "ai"),
            ("text_note", "user")
        ]

        for (index, item) in items.enumerated() {
            try await repo.addEntry(
                photoId: testPhotoId,
                kind: item.kind,
                contentJson: #"{"text":"Entry \#(index)"}"#,
                authoredBy: item.author
            )
        }

        let fetched = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(fetched.count, 3, "Repository should contain 3 entries for display")

        let kinds = Set(fetched.map(\.kind))
        XCTAssertTrue(kinds.contains("text_note"), "Should include text_note entries")
        XCTAssertTrue(kinds.contains("ai_turn"),   "Should include ai_turn entries")
    }

    /// Thread entries are returned in ascending sequence_number order.
    func testThreadEntriesRenderInChronologicalOrder() async throws {
        for i in 1...5 {
            try await repo.addEntry(
                photoId: testPhotoId,
                kind: "text_note",
                contentJson: #"{"text":"Message \#(i)"}"#,
                authoredBy: "user"
            )
        }

        let entries = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(entries.count, 5)

        let seqs = entries.map(\.sequenceNumber)
        for i in 1..<seqs.count {
            XCTAssertGreaterThan(
                seqs[i],
                seqs[i - 1],
                "Sequence \(seqs[i]) at index \(i) should be greater than \(seqs[i-1])"
            )
        }
    }

    /// Empty thread returns zero entries — view shows empty state.
    func testThreadViewHandlesEmptyThread() async throws {
        let entries = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(entries.count, 0, "New photo thread should have zero entries")
    }

    /// Adding a new entry causes the stream to emit an updated array.
    func testThreadViewRefreshesOnNewEntry() async throws {
        let stream = await repo.threadStream(for: testPhotoId)
        var iterator = stream.makeAsyncIterator()

        // First emission should be empty
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.count ?? 0, 0, "Initial stream value should be empty")

        // Add an entry
        try await repo.addEntry(
            photoId: testPhotoId,
            kind: "text_note",
            contentJson: #"{"text":"Hello thread"}"#,
            authoredBy: "user"
        )

        // Next emission should include the new entry
        let updated = try await iterator.next()
        XCTAssertEqual(updated?.count ?? 0, 1, "Stream should emit 1 entry after addEntry")
    }
}
