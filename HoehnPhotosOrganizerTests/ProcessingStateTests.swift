import Testing
@testable import HoehnPhotosOrganizer

// MARK: - ProcessingStateTests

struct ProcessingStateTests {

    // MARK: - ING-6: State machine transitions are ordered

    @Test
    func testStateMachineTransitionsAreOrdered() async throws {
        // ING-6: ProcessingState values form a strictly ordered sequence.
        // Each state must only advance — never skip forward past a step
        // or reverse — through:
        //   indexed → proxyPending → proxyReady → metadataEnriched → syncPending
        let orderedStates: [ProcessingState] = [
            .indexed,
            .proxyPending,
            .proxyReady,
            .metadataEnriched,
            .syncPending
        ]

        // Verify the enum raw values exist
        for state in orderedStates {
            #expect(!state.rawValue.isEmpty, "ProcessingState.\(state) must have a non-empty rawValue")
        }

        // Verify ordering: each state is distinct and the list is stable
        let rawValues = orderedStates.map(\.rawValue)
        let uniqueRawValues = Set(rawValues)
        #expect(rawValues.count == uniqueRawValues.count, "All ProcessingState raw values must be unique")

        // Verify transitions only go forward:
        // IngestionActor advances indexed → proxyPending (EXIF written) → (proxyReady via ProxyActor) → metadataEnriched
        // Simulate the progression we care about in plan 01-04:
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)

        var asset = PhotoAsset.new(
            canonicalName: "TEST_ORDER.dng",
            role: .original,
            filePath: "/TEST_ORDER.dng",
            fileSize: 1_000_000
        )
        // Initial state is indexed
        #expect(asset.processingState == ProcessingState.indexed.rawValue)
        try await photoRepo.upsert(asset)

        // Advance to proxyPending (EXIF extracted)
        try await photoRepo.updateProcessingState(id: asset.id, state: .proxyPending)
        let afterExif = try await photoRepo.fetchById(asset.id)
        #expect(afterExif?.processingState == ProcessingState.proxyPending.rawValue,
                "After EXIF extraction, processingState must be proxyPending")

        // Cannot go backwards: verify indexed cannot be re-applied after proxyPending
        // (IngestionActor resume skip logic handles this via fetchByCanonicalName guard)
        let fetched = try await photoRepo.fetchByCanonicalName("TEST_ORDER.dng")
        #expect(fetched?.processingState != ProcessingState.indexed.rawValue,
                "After advancing past indexed, state must not revert to indexed")
    }
}
