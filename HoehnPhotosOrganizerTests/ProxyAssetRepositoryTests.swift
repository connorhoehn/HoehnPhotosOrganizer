import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class ProxyAssetRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: ProxyAssetRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = ProxyAssetRepository(db: db)
    }

    private func makeProxy(id: String, photoId: String, byteSize: Int = 512_000) -> ProxyAsset {
        ProxyAsset(
            id: id,
            photoId: photoId,
            filePath: "/proxies/\(id).jpg",
            width: 1600,
            height: 1067,
            byteSize: byteSize,
            thumbnailPath: nil,
            thumbnailByteSize: nil,
            createdAt: ISO8601DateFormatter().string(from: .now)
        )
    }

    // MARK: - upsert + fetchByPhotoId round-trip

    func testUpsertAndFetchByPhotoIdRoundTrip() async throws {
        let proxy = makeProxy(id: "pr1", photoId: "photo-1")
        try await repo.upsert(proxy)

        let fetched = try await repo.fetchByPhotoId("photo-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "pr1")
        XCTAssertEqual(fetched?.byteSize, 512_000)
    }

    // MARK: - fetchByPhotoId returns nil for unknown photo

    func testFetchByPhotoIdReturnsNilForUnknownPhotoId() async throws {
        let result = try await repo.fetchByPhotoId("no-such-photo")
        XCTAssertNil(result, "fetchByPhotoId must return nil when no proxy exists for the given photoId")
    }

    // MARK: - upsert same id overwrites existing row

    func testUpsertSameIdOverwritesExistingProxy() async throws {
        var proxy = makeProxy(id: "pr2", photoId: "photo-2", byteSize: 100_000)
        try await repo.upsert(proxy)

        proxy.byteSize = 200_000
        try await repo.upsert(proxy)

        let fetched = try await repo.fetchByPhotoId("photo-2")
        XCTAssertEqual(fetched?.byteSize, 200_000,
                       "Second upsert with same id must overwrite the previous row")

        let count = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM proxy_assets WHERE photo_id = ?",
                             arguments: ["photo-2"]) ?? 0
        }
        XCTAssertEqual(count, 1, "Upserting the same id must not create duplicate rows")
    }
}
