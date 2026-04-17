import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class ConversationViewTests: XCTestCase {

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
            canonicalName: "photo_conv_view_\(UUID().uuidString).jpg",
            role: .original,
            filePath: "/tmp/test_conv_view.jpg",
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

    /// ConversationView shows text_note and ai_turn entries; other kinds are filtered out.
    func testConversationDisplaysMessageHistory() async throws {
        let items: [(kind: String, author: String, json: String)] = [
            ("text_note",     "user", #"{"text":"What lens did I use?"}"#),
            ("ai_turn",       "ai",   #"{"response":"Based on metadata, you used a 50mm f/1.4"}"#),
            ("print_attempt", "user", #"{"process":"Platinum"}"#),   // excluded from conversation
            ("text_note",     "user", #"{"text":"Can you describe the mood?"}"#),
            ("ai_turn",       "ai",   #"{"response":"Serene and contemplative"}"#)
        ]

        for item in items {
            try await repo.addEntry(
                photoId: testPhotoId,
                kind: item.kind,
                contentJson: item.json,
                authoredBy: item.author
            )
        }

        let all = try await repo.thread(for: testPhotoId)
        let conversation = all.filter { $0.kind == "text_note" || $0.kind == "ai_turn" }

        XCTAssertEqual(conversation.count, 4, "Should show 4 conversation entries (2 user + 2 AI)")
        XCTAssertEqual(all.count, 5, "Total repository has 5 entries")
    }

    /// Context window returns at most contextWindowSize entries (latest ones).
    func testContextWindowLimitPreventsTokenExplosion() async throws {
        let windowSize = ConversationView.contextWindowSize  // 10
        let totalEntries = windowSize + 5  // 15

        for i in 1...totalEntries {
            let isAI = i % 2 == 0
            let json = isAI
                ? #"{"response":"AI response \#(i)"}"#
                : #"{"text":"User message \#(i)"}"#
            try await repo.addEntry(
                photoId: testPhotoId,
                kind: isAI ? "ai_turn" : "text_note",
                contentJson: json,
                authoredBy: isAI ? "ai" : "user"
            )
        }

        let all = try await repo.thread(for: testPhotoId)
        XCTAssertEqual(all.count, totalEntries, "All entries should be persisted")

        // Mirror ConversationView.contextWindow slicing logic
        let contextWindow = all.count > windowSize ? Array(all.suffix(windowSize)) : all
        XCTAssertEqual(contextWindow.count, windowSize, "Context window capped at \(windowSize)")

        // Verify it uses the LATEST entries
        let expectedFirstSeq = all[all.count - windowSize].sequenceNumber
        XCTAssertEqual(
            contextWindow.first?.sequenceNumber,
            expectedFirstSeq,
            "Context window should start at sequence \(expectedFirstSeq)"
        )
    }

    /// Empty thread returns zero conversation entries.
    func testConversationViewHandlesEmptyThread() async throws {
        let entries = try await repo.thread(for: testPhotoId)
        let conversation = entries.filter { $0.kind == "text_note" || $0.kind == "ai_turn" }
        XCTAssertEqual(conversation.count, 0, "Empty thread yields zero conversation entries")
    }

    /// After adding entries, the last one has the highest sequence number (scroll target).
    func testScrollPositionFollowsLatestMessage() async throws {
        for i in 1...4 {
            try await repo.addEntry(
                photoId: testPhotoId,
                kind: i % 2 == 0 ? "ai_turn" : "text_note",
                contentJson: #"{"text":"message \#(i)"}"#,
                authoredBy: i % 2 == 0 ? "ai" : "user"
            )
        }

        let entries = try await repo.thread(for: testPhotoId)
        guard let last = entries.last else {
            XCTFail("Expected at least one entry")
            return
        }

        let maxSeq = entries.map(\.sequenceNumber).max() ?? 0
        XCTAssertEqual(
            last.sequenceNumber,
            maxSeq,
            "Last entry should have highest sequence number — this is the scroll target"
        )
    }
}
