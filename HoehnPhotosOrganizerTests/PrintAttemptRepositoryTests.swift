import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct PrintAttemptRepositoryTests {

    // MARK: - Helpers

    private func seedPhoto(id: String, in db: AppDatabase) async throws {
        let photoRepo = PhotoRepository(db: db)
        let asset = PhotoAsset.new(
            canonicalName: "\(id).dng",
            role: .original,
            filePath: "/tmp/\(id).dng",
            fileSize: 1024
        )
        // Override the auto-generated id to match what the test expects
        var seeded = asset
        seeded.id = id
        try await photoRepo.bulkUpsert([seeded])
    }

    private func makeAttempt(
        id: String = UUID().uuidString,
        photoId: String,
        printType: PrintType = .inkjetColor,
        paper: String = "Hahnemühle Photo Rag 308",
        outcome: PrintOutcome = .testing,
        outcomeNotes: String = "",
        printPhotoId: String? = nil,
        processSpecificFields: [String: AnyCodable] = [:]
    ) -> PrintAttempt {
        PrintAttempt(
            id: id,
            photoId: photoId,
            printType: printType,
            paper: paper,
            outcome: outcome,
            outcomeNotes: outcomeNotes,
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: printPhotoId,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: processSpecificFields,
            iccProfileName: nil,
            iccProfilePath: nil,
            renderingIntent: nil,
            blackPointCompensation: nil,
            brightnessCorrection: nil,
            saturationCorrection: nil,
            calibrationTemplate: nil,
            tileParametersJSON: nil,
            winnerTileIndex: nil,
            calibrationNotes: nil
        )
    }

    // MARK: - Tests

    @Test
    func testAddPrintAttempt() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-001", in: db)
        let repo = PrintAttemptRepository(db.dbPool)

        let attempt = makeAttempt(id: "pa-1", photoId: "photo-001")
        let entry = try await repo.addPrintAttempt(to: "photo-001", attempt: attempt)

        #expect(entry.kind == "print_attempt")
        #expect(entry.threadRootId == "photo-001")

        let fetched = try await repo.fetchAttempt(id: entry.id)
        let fa = try #require(fetched)
        #expect(fa.photoId == "photo-001")
        #expect(fa.printType == .inkjetColor)
    }

    @Test
    func testFetchPrintTimeline() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-002", in: db)
        let repo = PrintAttemptRepository(db.dbPool)

        for _ in 0..<3 {
            let attempt = makeAttempt(photoId: "photo-002")
            _ = try await repo.addPrintAttempt(to: "photo-002", attempt: attempt)
        }

        let timeline = try await repo.fetchTimelineForPhoto("photo-002")
        #expect(timeline.count == 3)
        #expect(timeline.allSatisfy { $0.kind == "print_attempt" })
    }

    @Test
    func testMultipleAttemptsOrdering() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-003", in: db)
        let repo = PrintAttemptRepository(db.dbPool)

        for _ in 0..<3 {
            let attempt = makeAttempt(photoId: "photo-003")
            _ = try await repo.addPrintAttempt(to: "photo-003", attempt: attempt)
        }

        let timeline = try await repo.fetchTimelineForPhoto("photo-003")
        let seqs = timeline.map(\.sequenceNumber)
        #expect(seqs == seqs.sorted(), "Sequence numbers must be ascending")
    }

    @Test
    func testPrintPhotoLinking() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-004", in: db)
        let repo = PrintAttemptRepository(db.dbPool)

        let attempt = makeAttempt(
            id: "pa-link",
            photoId: "photo-004",
            printPhotoId: "scan-photo-999"
        )
        let entry = try await repo.addPrintAttempt(to: "photo-004", attempt: attempt)

        let fetched = try await repo.fetchAttempt(id: entry.id)
        let fa = try #require(fetched)
        #expect(fa.printPhotoId == "scan-photo-999")
    }

    @Test
    func testProcessSpecificFieldsPersistence() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-005", in: db)
        let repo = PrintAttemptRepository(db.dbPool)

        let fields: [String: AnyCodable] = ["density": AnyCodable("1.42"), "zone": AnyCodable(5)]
        let attempt = makeAttempt(
            id: "pa-fields",
            photoId: "photo-005",
            processSpecificFields: fields
        )
        let entry = try await repo.addPrintAttempt(to: "photo-005", attempt: attempt)

        let fetched = try await repo.fetchAttempt(id: entry.id)
        let fa = try #require(fetched)
        let densityVal = fa.processSpecificFields["density"]
        let densityStr = try #require(densityVal?.value as? String)
        #expect(densityStr == "1.42")
    }
}
