import Foundation
import GRDB

actor ProxyAssetRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    func upsert(_ proxy: ProxyAsset) async throws {
        try await db.dbPool.write { db in try proxy.save(db) }
    }

    func fetchByPhotoId(_ photoId: String) async throws -> ProxyAsset? {
        try await db.dbPool.read { db in
            try ProxyAsset.filter(Column("photo_id") == photoId).fetchOne(db)
        }
    }
}
