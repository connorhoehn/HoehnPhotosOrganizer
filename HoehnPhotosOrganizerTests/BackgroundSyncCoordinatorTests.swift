import XCTest
@testable import HoehnPhotosOrganizer

final class BackgroundSyncCoordinatorTests: XCTestCase {

    func test_startPeriodicSync_schedulesAtInterval() throws {
        throw XCTSkip("Pending Wave 3 implementation: start with 1-minute interval, verify sync fires within 65 seconds")
    }

    func test_wifiOnlyGate_skipsSyncOnNonWifi() throws {
        throw XCTSkip("Pending Wave 3 implementation: simulate non-wifi path, verify syncIncremental NOT called")
    }

    func test_stopSync_cancelsTask() throws {
        throw XCTSkip("Pending Wave 3 implementation: start then stop, verify no further sync attempts")
    }

    func test_syncNow_bypassesInterval() throws {
        throw XCTSkip("Pending Wave 3 implementation: syncNow triggers immediate sync regardless of timer state")
    }
}
