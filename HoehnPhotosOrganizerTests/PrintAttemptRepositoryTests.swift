import XCTest

final class PrintAttemptRepositoryTests: XCTestCase {

    func testAddPrintAttempt() {
        XCTSkip("Implement in 05-01: CRUD for print attempts")
    }

    func testFetchPrintTimeline() {
        XCTSkip("Implement in 05-01: Verify querying all print attempts for a single photo returns chronological list")
    }

    func testMultipleAttemptsOrdering() {
        XCTSkip("Implement in 05-01: Verify sequence_number ordering is preserved across multiple attempts for same photo")
    }

    func testPrintPhotoLinking() {
        XCTSkip("Implement in 05-01: Verify print photo attachment creates photo_assets record with print_reference role")
    }

    func testProcessSpecificFieldsPersistence() {
        XCTSkip("Implement in 05-01: Verify type-specific fields serialize/deserialize via contentJson")
    }
}
