import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class DriveRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: DriveRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = DriveRepository(db: db)
    }

    private func makeDrive(id: String, label: String, freeBytes: Int = 100_000_000) -> DriveDB {
        let now = ISO8601DateFormatter().string(from: .now)
        return DriveDB(
            id: id,
            volumeLabel: label,
            mountPoint: "/Volumes/\(label)",
            totalBytes: 500_000_000_000,
            freeBytes: freeBytes,
            lastSeen: now,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - fetchAll empty

    func testFetchAllReturnsEmptyInitially() async throws {
        let all = try await repo.fetchAll()
        XCTAssertTrue(all.isEmpty, "Fresh database must contain no drives")
    }

    // MARK: - upsert + fetchAll sort order

    func testUpsertAndFetchAllReturnsSortedByVolumeLabel() async throws {
        try await repo.upsert(makeDrive(id: "z", label: "ZULU"))
        try await repo.upsert(makeDrive(id: "a", label: "ALPHA"))
        try await repo.upsert(makeDrive(id: "m", label: "MIKE"))

        let all = try await repo.fetchAll()
        XCTAssertEqual(all.map(\.volumeLabel), ["ALPHA", "MIKE", "ZULU"],
                       "fetchAll must be sorted alphabetically by volume_label")
    }

    // MARK: - upsert idempotency (same id → update)

    func testUpsertSameIdUpdatesFreeBytes() async throws {
        var drive = makeDrive(id: "d1", label: "BACKUP", freeBytes: 200_000_000)
        try await repo.upsert(drive)

        drive.freeBytes = 50_000_000
        try await repo.upsert(drive)

        let all = try await repo.fetchAll()
        XCTAssertEqual(all.count, 1, "Re-upserting same id must not create a duplicate row")
        XCTAssertEqual(all.first?.freeBytes, 50_000_000, "freeBytes must reflect latest upsert value")
    }

    // MARK: - fetchByVolumeLabel

    func testFetchByVolumeLabelReturnsMatchingDrive() async throws {
        try await repo.upsert(makeDrive(id: "d2", label: "SANDISK"))
        let found = try await repo.fetchByVolumeLabel("SANDISK")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "d2")
    }

    func testFetchByVolumeLabelReturnsNilForUnknownLabel() async throws {
        let result = try await repo.fetchByVolumeLabel("DOES_NOT_EXIST")
        XCTAssertNil(result, "fetchByVolumeLabel must return nil for a label not in the database")
    }

    // MARK: - delete

    func testDeleteRemovesDrive() async throws {
        try await repo.upsert(makeDrive(id: "d3", label: "SEAGATE"))
        try await repo.delete(id: "d3")
        let all = try await repo.fetchAll()
        XCTAssertTrue(all.isEmpty, "Drive must be removed from the database after delete")
    }
}
