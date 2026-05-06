import Testing
import Foundation
@testable import HoehnPhotosOrganizer

// Unit tests for the v35_fts5_search migration:
// - photo_assets_fts virtual table + 3 triggers (INSERT/UPDATE/DELETE)
// - PhotoRepository.buildSearchConditions keyword → FTS5 prefix query

struct FTS5SearchTests {

    // Make a PhotoAsset visible to search() — import_status must be 'library'
    // and hidden_from_library must be false (default).
    private func libraryPhoto(canonicalName: String, metadata: String? = nil) -> PhotoAsset {
        var asset = PhotoAsset.new(
            canonicalName: canonicalName,
            role: .original,
            filePath: "/test/\(canonicalName)",
            fileSize: 1_000_000
        )
        asset.importStatus = "library"
        asset.userMetadataJson = metadata
        return asset
    }

    // MARK: - Insert trigger

    @Test
    func testFTS5InsertTriggerPopulatesIndex() async throws {
        // Inserting a photo should fire photo_assets_fts_insert trigger so
        // the canonical_name is immediately findable via FTS5 keyword search.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        try await repo.upsert(libraryPhoto(canonicalName: "Kodak Portra 400.dng"))

        let results = try await repo.search(filter: SearchFilter(keywords: ["Kodak"]))
        #expect(results.count == 1, "Insert trigger must populate FTS5 index for keyword 'Kodak'")
        #expect(results.first?.canonicalName == "Kodak Portra 400.dng")
    }

    // MARK: - Prefix match

    @Test
    func testFTS5PrefixMatchWorks() async throws {
        // buildSearchConditions generates "word*" prefix queries so partial
        // words at the beginning of a token match without an exact substring hit.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        try await repo.upsert(libraryPhoto(canonicalName: "Fujifilm Velvia 100.tif"))

        let results = try await repo.search(filter: SearchFilter(keywords: ["Velvi"]))
        #expect(results.count == 1, "Prefix 'Velvi' must match token 'Velvia' via FTS5 prefix query")
    }

    // MARK: - Multi-word AND

    @Test
    func testFTS5MultiWordAndQueryRequiresBothTerms() async throws {
        // Space-separated words in a single keyword string are joined with " "
        // in the FTS5 query, meaning SQLite requires ALL tokens to match.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        try await repo.upsert(libraryPhoto(canonicalName: "Kodak Portra 400.dng"))
        try await repo.upsert(libraryPhoto(canonicalName: "Ilford HP5 Plus 400.dng"))

        let results = try await repo.search(filter: SearchFilter(keywords: ["Kodak 400"]))
        #expect(results.count == 1, "Multi-word keyword must require all tokens — only Kodak photo has both")
        #expect(results.first?.canonicalName == "Kodak Portra 400.dng")
    }

    // MARK: - Update trigger

    @Test
    func testFTS5UpdateTriggerKeepsIndexFresh() async throws {
        // When a photo's canonical_name changes via upsert (same id, new name),
        // the photo_assets_fts_update trigger must delete the old FTS row and
        // insert a new one so searches reflect the rename.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        var photo = libraryPhoto(canonicalName: "Agfa Scala 200.dng")
        try await repo.upsert(photo)

        // Rename by upserting same id with new canonical_name
        photo.canonicalName = "Agfa Vista 400.dng"
        photo.filePath = "/test/Agfa Vista 400.dng"
        try await repo.upsert(photo)

        let oldResults = try await repo.search(filter: SearchFilter(keywords: ["Scala"]))
        let newResults = try await repo.search(filter: SearchFilter(keywords: ["Vista"]))
        #expect(oldResults.isEmpty, "Old canonical_name 'Scala' must not appear after rename")
        #expect(newResults.count == 1, "New canonical_name 'Vista' must be findable after rename")
    }

    // MARK: - Delete trigger

    @Test
    func testFTS5DeleteTriggerCleansUpIndex() async throws {
        // permanentlyDelete() fires photo_assets_fts_delete trigger so the
        // FTS row is removed and the photo is no longer findable by keyword.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        let photo = libraryPhoto(canonicalName: "Ilford Delta 3200.dng")
        try await repo.upsert(photo)

        let before = try await repo.search(filter: SearchFilter(keywords: ["Ilford"]))
        #expect(before.count == 1, "Photo must be findable before delete")

        try await repo.permanentlyDelete(ids: [photo.id])

        let after = try await repo.search(filter: SearchFilter(keywords: ["Ilford"]))
        #expect(after.isEmpty, "Delete trigger must remove FTS row — deleted photo must not appear in results")
    }

    // MARK: - Metadata summary searchable

    @Test
    func testFTS5MetadataSummaryIsSearchable() async throws {
        // The FTS5 virtual table indexes metadata_summary (= user_metadata_json),
        // so tags stored in metadata are findable by keyword search even when
        // the canonical_name has no matching tokens.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)
        let photo = libraryPhoto(
            canonicalName: "IMG_0042.dng",
            metadata: #"{"tags":"Rollei Infrared 400 darkroom print"}"#
        )
        try await repo.upsert(photo)

        let results = try await repo.search(filter: SearchFilter(keywords: ["Rollei"]))
        #expect(results.count == 1, "Keyword in user_metadata_json must be found via FTS5 metadata_summary column")
    }
}
