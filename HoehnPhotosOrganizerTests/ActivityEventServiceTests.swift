import XCTest
@testable import HoehnPhotosOrganizer

/// Wave 2 stubs — event emission tests for ActivityEventService.
/// All tests skipped until ActivityEventService is implemented.
final class ActivityEventServiceTests: XCTestCase {

    func testEmitImportBatchEventCreatesRoot() throws {
        throw XCTSkip("Pending Wave 2 implementation")
    }

    func testEmitFrameExtractionCreatesChildUnderImport() throws {
        throw XCTSkip("Pending Wave 2 implementation")
    }

    func testEmitAdjustmentCreatesChildUnderPhoto() throws {
        throw XCTSkip("Pending Wave 2 implementation")
    }

    func testEmitNoteCreatesChildUnderEvent() throws {
        throw XCTSkip("Pending Wave 2 implementation")
    }

    func testEmitRollbackCreatesRollbackEvent() throws {
        throw XCTSkip("Pending Wave 2 implementation")
    }
}
