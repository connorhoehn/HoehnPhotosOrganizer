import CoreGraphics
import Foundation
import GRDB

/// Persists the result of a film-strip extraction to the catalog database.
///
/// FilmScanIngestionService is an actor so multiple concurrent calls are
/// serialised automatically. All INSERT operations (photo_assets, asset_lineage,
/// extraction_events, extraction_tool_logs) run inside a single `dbPool.write {}`
/// transaction — either every row is written or none are (atomic).
actor FilmScanIngestionService {

    // MARK: - Public API

    /// Persists a `FilmStripExtractionResult` and its pipeline tool logs to the catalog.
    ///
    /// Tool logs are saved inside the same write transaction as the `ExtractionEvent` row,
    /// guaranteeing atomicity: either both the event and all logs are committed, or neither are.
    ///
    /// - Parameters:
    ///   - result:         The extraction result produced by `FilmStripFrameExtractor`.
    ///   - sourcePhotoId:  The `photo_assets.id` of the parent scan asset.
    ///   - orientation:    The orientation string (`FilmStripOrientation.rawValue`).
    ///   - detectorMethod: The detector string (`FilmStripDetectionMethod.rawValue`).
    ///   - batchLabel:     Optional roll/batch label stored in `asset_lineage.metadata_json`.
    ///   - toolLogs:       Ordered `PipelineToolRun` steps captured during extraction.
    ///                     Pass `result.toolRuns` from `FilmStripFrameExtractor`. Defaults to
    ///                     empty for backwards compatibility with existing call sites.
    ///   - db:             The `AppDatabase` instance to write into.
    func persist(
        _ result: FilmStripExtractionResult,
        sourcePhotoId: String?,
        orientation: String,
        detectorMethod: String,
        batchLabel: String?,
        toolLogs: [PipelineToolRun] = [],
        db: AppDatabase,
        activityService: ActivityEventService? = nil,
        parentBatchEventId: String? = nil
    ) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        let sourceFileName = result.sourceURL.lastPathComponent
        let frameCount = result.exportedURLs.count
        let scanURL = result.sourceURL

        // Resolve file size outside the write transaction (avoids I/O on the DB writer thread).
        let parentFileSize = (try? scanURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        try await db.dbPool.write { database in
            // Ensure the parent scan always has a photo_assets row so lineage is never broken.
            // If the caller didn't provide a sourcePhotoId (e.g., scan was opened directly from
            // disk rather than imported first), look up or auto-create a hidden parent asset.
            let resolvedParentId: String?
            if let provided = sourcePhotoId {
                resolvedParentId = provided
            } else {
                let existing = try PhotoAsset
                    .filter(Column("file_path") == scanURL.path)
                    .fetchOne(database)
                if let existing {
                    resolvedParentId = existing.id
                } else {
                    var parentAsset = PhotoAsset.new(
                        canonicalName: scanURL.deletingPathExtension().lastPathComponent,
                        role: .original,
                        filePath: scanURL.path,
                        fileSize: parentFileSize
                    )
                    parentAsset.hiddenFromLibrary = true
                    try parentAsset.insert(database)
                    resolvedParentId = parentAsset.id
                }
            }

            for (index, url) in result.exportedURLs.enumerated() {
                // Derive a canonical name from the exported file name (no extension).
                let frameName = url.deletingPathExtension().lastPathComponent

                // Read actual file size; fall back to 0 if the file is not yet
                // flushed or the URL is unavailable (e.g. in unit tests with stubs).
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                var asset = PhotoAsset.new(
                    canonicalName: frameName,
                    role: .workflowOutput,
                    filePath: url.path,
                    fileSize: fileSize
                )
                asset.processingState = ProcessingState.proxyPending.rawValue
                try asset.insert(database)

                // One asset_lineage row per frame linking the parent scan to the child frame.
                let metadataJson: String? = batchLabel.map { label in
                    "{\"batchLabel\":\"\(label)\"}"
                }
                let rect = index < result.frameRects.count ? result.frameRects[index] : nil
                let lineage = AssetLineage(
                    id: UUID().uuidString,
                    parentPhotoId: resolvedParentId,
                    childPhotoId: asset.id,
                    operation: "film_strip_extract",
                    frameIndex: index + 1,  // 1-based frame index
                    sourceFileName: sourceFileName,
                    createdAt: now,
                    metadataJson: metadataJson,
                    cropRectX: rect.map { Double($0.origin.x) },
                    cropRectY: rect.map { Double($0.origin.y) },
                    cropRectW: rect.map { Double($0.width) },
                    cropRectH: rect.map { Double($0.height) }
                )
                try lineage.insert(database)
            }

            // One extraction_events row for the entire batch.
            let event = ExtractionEvent(
                id: UUID().uuidString,
                sourcePhotoId: resolvedParentId,
                sourceFileName: sourceFileName,
                orientation: orientation,
                detectorMethod: detectorMethod,
                frameCount: frameCount,
                manifestPath: result.lineageManifestURL?.path,
                createdAt: now
            )
            try event.insert(database)

            // CP-1: Persist tool logs atomically in the same write transaction.
            // If any log insert fails, the entire transaction is rolled back — the event
            // and its logs are always written together or not at all.
            for (index, run) in toolLogs.enumerated() {
                let log = ExtractionToolLog.from(run: run, extractionId: event.id, order: index)
                try log.insert(database)
            }
        }

        // Emit per-frame activity events (fire-and-forget — never blocks ingestion).
        if let service = activityService, let batchId = parentBatchEventId {
            for url in result.exportedURLs {
                let frameName = url.deletingPathExtension().lastPathComponent
                Task {
                    try? await service.emitFrameExtraction(
                        parentBatchId: batchId,
                        photoAssetId: url.lastPathComponent,  // frame file name as asset identifier
                        frameName: frameName,
                        success: true
                    )
                }
            }
        }
    }
}
