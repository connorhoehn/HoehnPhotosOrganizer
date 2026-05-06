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

    // MARK: - ActivityEventKind

    @Test
    func testActivityEventKindCriticalRawValuesMatchDatabaseColumnValues() {
        #expect(ActivityEventKind.importBatch.rawValue        == "import_batch")
        #expect(ActivityEventKind.adjustment.rawValue         == "adjustment")
        #expect(ActivityEventKind.colorGrade.rawValue         == "color_grade")
        #expect(ActivityEventKind.printAttempt.rawValue       == "print_attempt")
        #expect(ActivityEventKind.note.rawValue               == "note")
        #expect(ActivityEventKind.rollback.rawValue           == "rollback")
        #expect(ActivityEventKind.metadataEnrichment.rawValue == "metadata_enrichment")
        #expect(ActivityEventKind.printJob.rawValue           == "print_job")
        #expect(ActivityEventKind.curveLinearized.rawValue    == "curve_linearized")
        #expect(ActivityEventKind.versionCreated.rawValue     == "version_created")
    }

    @Test
    func testActivityEventKindAllCasesHaveNonEmptyFilterLabels() {
        for kind in ActivityEventKind.allCases {
            #expect(!kind.filterLabel.isEmpty,
                    "ActivityEventKind.\(kind.rawValue).filterLabel must not be empty")
        }
    }

    // MARK: - SmartCollectionRule enums

    @Test
    func testSmartCollectionRuleFieldRawValuesMatchDatabaseColumnValues() {
        #expect(SmartCollectionRule.Field.curationState.rawValue   == "curation_state")
        #expect(SmartCollectionRule.Field.processingState.rawValue == "processing_state")
        #expect(SmartCollectionRule.Field.syncState.rawValue       == "sync_state")
        #expect(SmartCollectionRule.Field.role.rawValue            == "role")
        #expect(SmartCollectionRule.Field.driveId.rawValue         == "drive_id")
    }

    @Test
    func testSmartCollectionRuleOperatorRawValuesMatchQueryConventions() {
        #expect(SmartCollectionRule.Operator.equals.rawValue      == "equals")
        #expect(SmartCollectionRule.Operator.notEquals.rawValue   == "not_equals")
        #expect(SmartCollectionRule.Operator.isNull.rawValue      == "is_null")
        #expect(SmartCollectionRule.Operator.isNotNull.rawValue   == "is_not_null")
    }

    // MARK: - PrintType

    @Test
    func testPrintTypeRawValuesMatchDatabaseColumnValues() {
        #expect(PrintType.inkjetColor.rawValue             == "inkjet_color")
        #expect(PrintType.inkjetBW.rawValue                == "inkjet_bw")
        #expect(PrintType.silverGelatinDarkroom.rawValue   == "silver_gelatin_darkroom")
        #expect(PrintType.platinumPalladium.rawValue       == "platinum_palladium")
        #expect(PrintType.cyanotype.rawValue               == "cyanotype")
        #expect(PrintType.digitalNegative.rawValue         == "digital_negative")
    }

    @Test
    func testPrintTypeAllCasesHaveNonEmptyDisplayNames() {
        for type_ in PrintType.allCases {
            #expect(!type_.displayName.isEmpty,
                    "PrintType.\(type_.rawValue).displayName must not be empty")
        }
    }

    // MARK: - PrintOutcome

    @Test
    func testPrintOutcomeRawValuesMatchDatabaseColumnValues() {
        #expect(PrintOutcome.pass.rawValue             == "pass")
        #expect(PrintOutcome.fail.rawValue             == "fail")
        #expect(PrintOutcome.needsAdjustment.rawValue  == "needs_adjustment")
        #expect(PrintOutcome.testing.rawValue          == "testing")
    }

    // MARK: - OutboxStatus

    @Test
    func testOutboxStatusRawValuesMatchDatabaseColumnValues() {
        #expect(OutboxStatus.pending.rawValue    == "pending")
        #expect(OutboxStatus.processing.rawValue == "processing")
        #expect(OutboxStatus.done.rawValue       == "done")
        #expect(OutboxStatus.failed.rawValue     == "failed")
    }

    // MARK: - TriageJob enums

    @Test
    func testTriageJobStatusAndSourceRawValuesMatchDatabaseColumnValues() {
        #expect(TriageJobStatus.open.rawValue      == "open")
        #expect(TriageJobStatus.complete.rawValue  == "complete")
        #expect(TriageJobStatus.archived.rawValue  == "archived")

        #expect(TriageJobSource.importBatch.rawValue == "import_batch")
        #expect(TriageJobSource.manual.rawValue      == "manual")
        #expect(TriageJobSource.split.rawValue       == "split")
    }
}
