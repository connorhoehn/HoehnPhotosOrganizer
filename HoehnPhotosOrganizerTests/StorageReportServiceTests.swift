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

    func testDerivativesBytesIncludesAllThreeDerivativeRoles() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            for (idx, role) in ["workflow_output", "edited_export", "print_reference"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                        processing_state, curation_state, sync_state, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'indexed', 'needs_review', 'local_only', ?, ?)
                """, arguments: ["deriv-\(idx)", "deriv-\(idx).tif", role, "/exports/deriv-\(idx).tif", (idx + 1) * 1000, now, now])
            }
        }
        let report = try await service.generateReport()
        // workflow_output(1000) + edited_export(2000) + print_reference(3000) = 6000
        XCTAssertEqual(report.derivativesBytes, 6000)
        XCTAssertEqual(report.originalsBytes, 0)
    }

    func testExternalReferenceBytesCountedSeparately() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('ext1', 'ext1.jpg', 'external_reference', '/refs/ext1.jpg', 4500,
                    'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
        }
        let report = try await service.generateReport()
        XCTAssertEqual(report.externalReferencesBytes, 4500)
        XCTAssertEqual(report.originalsBytes, 0)
        XCTAssertEqual(report.derivativesBytes, 0)
    }

    func testTotalCataloggedBytesIsSumOfAllCategories() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES
                    ('o1', 'orig.NEF',  'original',          '/drive/orig.NEF',  1000, 'proxy_ready', 'needs_review', 'local_only', ?, ?),
                    ('d1', 'deriv.tif', 'workflow_output',   '/exports/d.tif',    200, 'indexed',     'needs_review', 'local_only', ?, ?),
                    ('e1', 'ext.jpg',   'external_reference','/refs/ext.jpg',     300, 'indexed',     'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now, now, now, now, now])
            try db.execute(sql: """
                INSERT INTO proxy_assets (id, photo_id, file_path, width, height, byte_size, created_at)
                VALUES ('pr1', 'o1', '/proxies/orig.jpg', 1600, 1067, 500, ?)
            """, arguments: [now])
        }
        let report = try await service.generateReport()
        // originals(1000) + proxies(500) + derivatives(200) + external(300) = 2000
        XCTAssertEqual(report.totalCataloggedBytes, 2000)
    }

    func testDriveBreakdownDerivativeBytesForDrivePhotos() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO drives (id, volume_label, mount_point, total_bytes, free_bytes, last_seen, created_at, updated_at)
                VALUES ('drv1', 'EXTERNAL1', '/Volumes/EXTERNAL1', 1000000000, 500000000, ?, ?, ?)
            """, arguments: [now, now, now])
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('exp1', 'export.tif', 'workflow_output', 'EXTERNAL1/export.tif', 7500,
                    'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
        }
        let report = try await service.generateReport()
        let breakdown = try XCTUnwrap(report.driveBreakdowns.first { $0.volumeLabel == "EXTERNAL1" })
        XCTAssertEqual(breakdown.derivativeBytes, 7500)
        XCTAssertEqual(breakdown.originalBytes, 0)
    }
}
