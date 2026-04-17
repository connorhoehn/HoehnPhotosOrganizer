import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class StorageReportServiceTests: XCTestCase {
    var db: AppDatabase!
    var service: StorageReportService!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = StorageReportService(db: db)
    }

    func testEmptyLibraryReturnsZeroTotals() async throws {
        let report = try await service.generateReport()
        XCTAssertEqual(report.originalsBytes, 0)
        XCTAssertEqual(report.proxiesBytes, 0)
        XCTAssertEqual(report.derivativesBytes, 0)
        XCTAssertTrue(report.driveBreakdowns.isEmpty)
    }

    func testReportDistinguishesOriginalsByRole() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES (?, ?, 'original', 'DRIVE1/photo1.NEF', 2000, 'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: ["id1", "photo1.NEF", now, now])
        }
        let report = try await service.generateReport()
        XCTAssertEqual(report.originalsBytes, 2000)
        XCTAssertEqual(report.proxiesBytes, 0)
    }

    func testReportCountsProxyBytesFromProxyAssetsTable() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('pa1', 'photo1.NEF', 'original', 'DRIVE1/photo1.NEF', 1000, 'proxy_ready', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO proxy_assets (id, photo_id, file_path, width, height, byte_size, created_at)
                VALUES ('pr1', 'pa1', '/proxies/photo1.jpg', 1600, 1067, 800, ?)
            """, arguments: [now])
        }
        let report = try await service.generateReport()
        XCTAssertEqual(report.proxiesBytes, 800)
    }

    func testReportReturnsDriveBreakdownPerDrive() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO drives (id, volume_label, mount_point, total_bytes, free_bytes, last_seen, created_at, updated_at)
                VALUES ('d1', 'DRIVE1', '/Volumes/DRIVE1', 500000000000, 100000000000, ?, ?, ?)
            """, arguments: [now, now, now])
        }
        let report = try await service.generateReport()
        XCTAssertEqual(report.driveBreakdowns.count, 1)
        XCTAssertEqual(report.driveBreakdowns.first?.volumeLabel, "DRIVE1")
    }
}
