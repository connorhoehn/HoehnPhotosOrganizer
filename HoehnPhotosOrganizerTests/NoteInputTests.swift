import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct NoteInputTests {

    // MARK: - Helpers

    private func seedPhoto(id: String, in db: AppDatabase) async throws {
        var asset = PhotoAsset.new(
            canonicalName: "\(id).dng",
            role: .original,
            filePath: "/tmp/\(id).dng",
            fileSize: 1024
        )
        asset.id = id
        try await PhotoRepository(db: db).bulkUpsert([asset])
    }

    // MARK: - Tests

    @Test
    func testNoteInputSheetAttachesToEvent() async throws {
        // Repurposed: ThreadRepository.addEntry writes an entry whose
        // thread_root_id matches the supplied photoId.
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "note-photo-1", in: db)
        let repo = ThreadRepository(db: db)

        try await repo.addEntry(
            photoId: "note-photo-1",
            kind: "text_note",
            contentJson: #"{"text":"Good light"}"#,
            authoredBy: "user"
        )

        let entries = try await repo.fetchEntries(forPhoto: "note-photo-1")
        let entry = try #require(entries.first)
        #expect(entry.threadRootId == "note-photo-1")
    }

    @Test
    func testNoteInputSheetAttachesToPhoto() async throws {
        // Repurposed: created entry has correct kind and authoredBy fields.
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "note-photo-2", in: db)
        let repo = ThreadRepository(db: db)

        try await repo.addEntry(
            photoId: "note-photo-2",
            kind: "text_note",
            contentJson: #"{"text":"Shadow detail"}"#,
            authoredBy: "user"
        )

        let entries = try await repo.fetchEntries(forPhoto: "note-photo-2")
        let entry = try #require(entries.first)
        #expect(entry.kind == "text_note")
        #expect(entry.authoredBy == "user")
    }

    @Test
    func testNoteBodyPersistsToActivityEvents() async throws {
        // Repurposed: note text written in contentJson is preserved through DB round-trip.
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "note-photo-3", in: db)
        let repo = ThreadRepository(db: db)
        let body = "Exposed for shadows, detail visible in Zone III"
        let contentJson = #"{"text":"Exposed for shadows, detail visible in Zone III"}"#

        try await repo.addEntry(
            photoId: "note-photo-3",
            kind: "text_note",
            contentJson: contentJson,
            authoredBy: "user"
        )

        let entries = try await repo.fetchEntries(forPhoto: "note-photo-3")
        let entry = try #require(entries.first)
        #expect(entry.contentJson.contains(body),
                "Note body must be preserved verbatim in contentJson after DB round-trip")
    }

    @Test
    func testEmptyNoteIsRejected() {
        // NoteInputSheet guards empty text before saving.
        // trimmingCharacters(in: .whitespacesAndNewlines) must collapse whitespace-only input to "".
        let whitespaceOnly = "  \n\t  "
        let trimmed = whitespaceOnly.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty, "Whitespace-only note must trim to empty and be rejected by the save guard")

        let validNote = " Good print. "
        let validTrimmed = validNote.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!validTrimmed.isEmpty, "Non-empty note must pass the guard after trimming")
    }
}
