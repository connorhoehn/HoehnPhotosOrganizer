import Testing
@testable import HoehnPhotosOrganizer

// MARK: - CoreEnumTests
//
// These tests pin the rawValue strings for core domain enums to their exact SQLite column values.
// A camelCase drift (e.g. "needs_review" → "needsReview") silently makes every filtered query
// return no results without a compile error.

struct CoreEnumTests {

    // MARK: - PhotoRole

    @Test
    func testPhotoRoleRawValuesMatchDatabaseColumnValues() {
        #expect(PhotoRole.original.rawValue           == "original")
        #expect(PhotoRole.editedExport.rawValue       == "edited_export")
        #expect(PhotoRole.proxy.rawValue              == "proxy")
        #expect(PhotoRole.workflowOutput.rawValue     == "workflow_output")
        #expect(PhotoRole.printReference.rawValue     == "print_reference")
        #expect(PhotoRole.externalReference.rawValue  == "external_reference")
    }

    @Test
    func testPhotoRoleAllCasesHaveNonEmptyDisplayNames() {
        for role in PhotoRole.allCases {
            #expect(!role.displayName.isEmpty,
                    "PhotoRole.\(role.rawValue).displayName must not be empty")
        }
    }

    // MARK: - CurationState

    @Test
    func testCurationStateRawValuesMatchDatabaseColumnValues() {
        #expect(CurationState.keeper.rawValue      == "keeper")
        #expect(CurationState.archive.rawValue     == "archive")
        #expect(CurationState.needsReview.rawValue == "needs_review")
        #expect(CurationState.rejected.rawValue    == "rejected")
        #expect(CurationState.deleted.rawValue     == "deleted")
    }

    // MARK: - SyncState

    @Test
    func testSyncStateRawValuesMatchDatabaseColumnValues() {
        #expect(SyncState.localOnly.rawValue == "local_only")
        #expect(SyncState.queued.rawValue    == "queued")
        #expect(SyncState.synced.rawValue    == "synced")
        #expect(SyncState.failed.rawValue    == "failed")
    }

    @Test
    func testSyncStateAllCasesHaveNonEmptyLabels() {
        for state in SyncState.allCases {
            #expect(!state.label.isEmpty,
                    "SyncState.\(state.rawValue).label must not be empty")
        }
    }
}
