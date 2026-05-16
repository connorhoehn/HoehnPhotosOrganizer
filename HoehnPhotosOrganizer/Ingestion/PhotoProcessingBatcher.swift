import Foundation
import GRDB

/// Batches per-photo writes from the proxy-generation and face-indexing pipelines into
/// single GRDB transactions. Each individual `dbPool.write` carries an fsync; 1000 of them
/// take 1–5 seconds, while 1000 inserts inside one transaction finish in under 100 ms.
///
/// Pattern: callers `append…` results as ML work completes. The batcher auto-flushes when
/// any buffer crosses `flushThreshold`. The caller is responsible for one final `flush()`
/// at end-of-pipeline to commit any partial batch left over.
///
/// Why an actor: serialised buffer mutation under structured concurrency, and a natural
/// rendezvous point for K parallel workers feeding the same single-writer SQLite.
actor PhotoProcessingBatcher {
    private let db: AppDatabase
    private let flushThreshold: Int

    private var proxyAssets: [ProxyAsset] = []
    private var processingStateUpdates: [(id: String, state: ProcessingState, errorMessage: String?)] = []
    private var proxyFieldStamps: [(id: String, proxyPath: String, sourceDriveUUID: String?, sourceDrivePath: String?)] = []
    private var clipEmbeddings: [(photoAssetId: String, embedding: [Float])] = []
    private var touchUpdatedAtIds: Set<String> = []
    private var faceEmbeddings: [FaceEmbedding] = []
    private var faceIndexedIds: Set<String> = []

    /// Default flushThreshold of 10. Chosen for UX smoothness: the per-job processing
    /// panel polls every ~500 ms; a 10-item batch flushes ~once per second at typical
    /// per-photo work rates, so the progress bars advance in visually continuous steps
    /// rather than the 100-photo jumps the previous threshold produced. The DB cost
    /// difference (100 vs 10 transactions per 1000 photos) is in the noise.
    init(db: AppDatabase, flushThreshold: Int = 10) {
        self.db = db
        self.flushThreshold = flushThreshold
    }

    // MARK: - Append (proxy-generation pipeline)

    func appendProxyAsset(_ asset: ProxyAsset) async throws {
        proxyAssets.append(asset)
        try await maybeFlush()
    }

    func appendProcessingState(id: String, state: ProcessingState, errorMessage: String? = nil) async throws {
        processingStateUpdates.append((id, state, errorMessage))
        try await maybeFlush()
    }

    func appendProxyFields(id: String, proxyPath: String, sourceDriveUUID: String?, sourceDrivePath: String?) async throws {
        proxyFieldStamps.append((id, proxyPath, sourceDriveUUID, sourceDrivePath))
        try await maybeFlush()
    }

    func appendClipEmbedding(photoAssetId: String, embedding: [Float]) async throws {
        clipEmbeddings.append((photoAssetId, embedding))
        try await maybeFlush()
    }

    func appendTouchUpdatedAt(id: String) async throws {
        touchUpdatedAtIds.insert(id)
        try await maybeFlush()
    }

    // MARK: - Append (face-indexing pipeline)

    func appendFaceEmbeddings(_ records: [FaceEmbedding], faceIndexedPhotoId: String) async throws {
        faceEmbeddings.append(contentsOf: records)
        faceIndexedIds.insert(faceIndexedPhotoId)
        try await maybeFlush()
    }

    // MARK: - Flush

    /// Commit all buffered writes in one transaction. Idempotent — clears buffers on success.
    /// Call at the end of each pipeline run to drain the final partial batch.
    func flush() async throws {
        guard bufferTotal > 0 else { return }

        let proxies = takeAndClear(&proxyAssets)
        let stateUpdates = takeAndClear(&processingStateUpdates)
        let stamps = takeAndClear(&proxyFieldStamps)
        let clipEmb = takeAndClear(&clipEmbeddings)
        let touches = touchUpdatedAtIds; touchUpdatedAtIds.removeAll(keepingCapacity: true)
        let faces = takeAndClear(&faceEmbeddings)
        let faceIds = faceIndexedIds; faceIndexedIds.removeAll(keepingCapacity: true)

        let now = ISO8601DateFormatter().string(from: .now)

        try await db.dbPool.write { dbConn in
            for var asset in proxies {
                try asset.save(dbConn)
            }
            for upd in stateUpdates {
                try dbConn.execute(
                    sql: """
                        UPDATE photo_assets
                        SET processing_state = ?, error_message = ?, updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [upd.state.rawValue, upd.errorMessage, now, upd.id]
                )
            }
            for stamp in stamps {
                try dbConn.execute(
                    sql: """
                        UPDATE photo_assets
                        SET proxy_path = ?, source_drive_uuid = ?, source_drive_path = ?, updated_at = ?
                        WHERE id = ?
                    """,
                    arguments: [stamp.proxyPath, stamp.sourceDriveUUID, stamp.sourceDrivePath, now, stamp.id]
                )
            }
            for emb in clipEmb {
                let json = (try? JSONSerialization.data(withJSONObject: emb.embedding.map { Double($0) }))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try dbConn.execute(
                    sql: """
                        INSERT INTO embeddings (photo_asset_id, embedding_json, created_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(photo_asset_id) DO UPDATE SET
                            embedding_json = excluded.embedding_json,
                            created_at = excluded.created_at
                    """,
                    arguments: [emb.photoAssetId, json, now]
                )
            }
            for id in touches {
                try dbConn.execute(
                    sql: "UPDATE photo_assets SET updated_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
            for var record in faces {
                try record.save(dbConn)
            }
            for id in faceIds {
                try dbConn.execute(
                    sql: "UPDATE photo_assets SET face_indexed_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, id]
                )
            }
        }
    }

    // MARK: - Private

    private func maybeFlush() async throws {
        if bufferTotal >= flushThreshold {
            try await flush()
        }
    }

    private var bufferTotal: Int {
        proxyAssets.count
            + processingStateUpdates.count
            + proxyFieldStamps.count
            + clipEmbeddings.count
            + touchUpdatedAtIds.count
            + faceEmbeddings.count
            + faceIndexedIds.count
    }

    private func takeAndClear<T>(_ buffer: inout [T]) -> [T] {
        let copy = buffer
        buffer.removeAll(keepingCapacity: true)
        return copy
    }
}
