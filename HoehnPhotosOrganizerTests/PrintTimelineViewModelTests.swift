import Foundation
import Testing
@testable import HoehnPhotosOrganizer

@MainActor
struct PrintTimelineViewModelTests {

    // MARK: - Test loadTimeline method loads print attempts for a photo

    @Test func testLoadTimelineLoadsAttemptsForPhoto() async throws {
        let db = try AppDatabase.makeInMemory()
        let repository = PrintAttemptRepository(db.dbPool)

        // Create a print attempt
        let attempt = PrintAttempt(
            id: UUID().uuidString,
            photoId: "photo-001",
            printType: .platinumPalladium,
            paper: "Platinum Palladium Paper",
            outcome: .pass,
            outcomeNotes: "Good density",
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        // Add attempt to repository
        _ = try await repository.addPrintAttempt(to: "photo-001", attempt: attempt)

        // Create view model and load timeline
        let viewModel = PrintTimelineViewModel(db.dbPool)
        await viewModel.loadTimeline(for: "photo-001")

        // Verify timeline entries are loaded
        #expect(viewModel.timelineEntries.count == 1)
        #expect(viewModel.timelineEntries.first?.printType == .platinumPalladium)
        #expect(viewModel.timelineEntries.first?.paper == "Platinum Palladium Paper")
    }

    // MARK: - Test loadTimeline with multiple attempts ordered chronologically

    @Test func testLoadTimelineOrdersChronologically() async throws {
        let db = try AppDatabase.makeInMemory()
        let repository = PrintAttemptRepository(db.dbPool)

        let baseDate = Date()

        // Create three attempts with different dates
        for i in 0..<3 {
            let attempt = PrintAttempt(
                id: UUID().uuidString,
                photoId: "photo-001",
                printType: .platinumPalladium,
                paper: "Paper \(i)",
                outcome: .pass,
                outcomeNotes: "Attempt \(i)",
                curveFileId: nil,
                curveFileName: nil,
                printPhotoId: nil,
                createdAt: baseDate.addingTimeInterval(Double(i) * 3600),
                updatedAt: baseDate.addingTimeInterval(Double(i) * 3600),
                processSpecificFields: [:]
            )
            _ = try await repository.addPrintAttempt(to: "photo-001", attempt: attempt)
        }

        // Load timeline
        let viewModel = PrintTimelineViewModel(db.dbPool)
        await viewModel.loadTimeline(for: "photo-001")

        // Verify entries are chronological (oldest first)
        #expect(viewModel.timelineEntries.count == 3)
        #expect(viewModel.timelineEntries[0].paper == "Paper 0")
        #expect(viewModel.timelineEntries[1].paper == "Paper 1")
        #expect(viewModel.timelineEntries[2].paper == "Paper 2")
    }

    // MARK: - Test loadTimeline error handling

    @Test func testLoadTimelineHandlesEmptyTimeline() async throws {
        let db = try AppDatabase.makeInMemory()

        let viewModel = PrintTimelineViewModel(db.dbPool)
        await viewModel.loadTimeline(for: "photo-nonexistent")

        // Verify empty timeline
        #expect(viewModel.timelineEntries.count == 0)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Test isLoading state transitions

    @Test func testLoadTimelineUpdatesLoadingState() async throws {
        let db = try AppDatabase.makeInMemory()

        let viewModel = PrintTimelineViewModel(db.dbPool)
        #expect(viewModel.isLoading == false)

        // Call loadTimeline (starts loading)
        let task = Task {
            await viewModel.loadTimeline(for: "photo-001")
        }

        // Wait for completion
        _ = await task.result

        // Verify loading is complete
        #expect(viewModel.isLoading == false)
    }
}
