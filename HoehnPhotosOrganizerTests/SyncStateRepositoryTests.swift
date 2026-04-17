import XCTest
@testable import HoehnPhotosOrganizer

final class SyncStateRepositoryTests: XCTestCase {

    func test_getLastSyncTimestamp_defaultsToZero() throws {
        throw XCTSkip("Pending Wave 1 implementation: fresh DB returns 0 for lastSyncTimestamp")
    }

    func test_setAndGetLastSyncTimestamp_roundTrip() throws {
        throw XCTSkip("Pending Wave 1 implementation: set timestamp 1711000000, get returns same value")
    }

    func test_updatePhotoSyncStatus_setsStatusAndError() throws {
        throw XCTSkip("Pending Wave 1 implementation: update photo sync_status to 'error' with reason, query back confirms both fields")
    }

    func test_getPhotosModifiedSince_returnsOnlyNewer() throws {
        throw XCTSkip("Pending Wave 1 implementation: 3 photos with different updated_at, query with middle timestamp returns only newest")
    }

    func test_syncStatusCounts_groupsByStatus() throws {
        throw XCTSkip("Pending Wave 1 implementation: 5 localOnly + 3 synced → counts dict has correct values")
    }

    func test_photosWithSyncErrors_filtersCorrectly() throws {
        throw XCTSkip("Pending Wave 1 implementation: 2 error + 3 synced → returns only 2 error photos")
    }
}
