import Foundation
import AppKit
import ImageIO
import CoreGraphics
import GRDB

// MARK: - CancellationToken

final class DriveScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}

// MARK: - DrivePreviewService

/// Actor that scans a mounted volume, generates thumbnails, and populates the per-drive SQLite.
/// Designed for long background runs — callers poll `scanProgress/scannedCount/totalCount`.
actor DrivePreviewService {

    private(set) var isScanning  = false
    private(set) var scanProgress: Double = 0  // 0…1
    private(set) var scannedCount = 0
    private(set) var totalCount   = 0

    // Detailed progress state (polled by MountedDriveState)
    private(set) var currentStage: IndexingStage = .idle
    private(set) var currentFilename: String = ""
    private(set) var folderCount: Int = 0
    private(set) var rawCount: Int = 0
    private(set) var jpegCount: Int = 0
    private(set) var otherCount: Int = 0
    private(set) var skippedCount: Int = 0
    private(set) var logLines: [String] = []   // rolling, max 40

    // Thumbnail-phase specific counters (polled separately so UI can show distinct progress)
    private(set) var thumbnailsDone:  Int = 0
    private(set) var thumbnailsTotal: Int = 0

    // Static so enumerateImages can be nonisolated (no actor hop needed off the hot path)
    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        "dng", "raw", "rwl", "pef", "srw", "x3f", "3fr",
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif",
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        "dng", "raw", "rwl", "pef", "srw", "x3f", "3fr",
    ]

    // Lazy-initialised orientation service (only created once per service instance)
    private lazy var orientationService = OrientationClassificationService()

    // MARK: - Public

    /// Scan a mounted volume and upsert all photos into `database`.
    /// Call from any context; progress can be polled via the actor properties.
    func indexDrive(
        mountPoint: URL,
        volumeUUID: String,
        database: DrivePreviewDatabase,
        cancelToken: DriveScanCancellationToken,
        usedBytes: Int64 = 0          // drive's used space — used as denominator during discovery
    ) async {
        guard !isScanning else { return }

        // Reset everything
        isScanning = true; scannedCount = 0; totalCount = 0; scanProgress = 0
        rawCount = 0; jpegCount = 0; otherCount = 0; skippedCount = 0
        folderCount = 0; currentFilename = ""; logLines = []
        thumbnailsDone = 0; thumbnailsTotal = 0
        currentStage = .discovering

        let startTime = Date()
        appendLog("Starting scan — \(mountPoint.lastPathComponent) (\(mountPoint.path))")

        let thumbsDir = DrivePreviewDatabase.thumbsURL(for: volumeUUID)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        // Load existing records BEFORE enumeration so we can classify new vs. unchanged
        // without a per-file DB lookup on the hot path.
        appendLog("Loading existing index…")
        let existingByPath: [String: DrivePhotoRecord] = (try? await database.dbPool.read { db in
            let all = try DrivePhotoRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: all.map { ($0.relativePath, $0) })
        }) ?? [:]

        // Switch to .indexing so the UI shows the file-count counter instead of
        // the indeterminate "found N…" bar from the old pure-discovery stage.
        currentStage = .indexing

        // Single-pass: enumerate + index simultaneously.
        // Records are flushed to the DB every 50 files so the grid starts populating
        // within seconds and Stop at any point leaves usable partial results.
        let iso8601   = ISO8601DateFormatter()
        let mountPath = mountPoint.path
        let driveBytes = max(1, usedBytes)
        var lastLogFolder = ""
        let rootDepth = mountPoint.pathComponents.count
        var pendingBatch: [DrivePhotoRecord] = []
        var thumbsToDelete: [String] = []
        var bytesFound: Int64 = 0
        let logEvery = 2_000   // log a summary line every N files

        for await (url, fileSize, modDate) in enumerateStream(at: mountPoint) {
            guard !cancelToken.isCancelled else { break }

            // Folder accounting
            let folderURL  = url.deletingLastPathComponent()
            let folderPath = folderURL.path
            if folderPath != lastLogFolder {
                lastLogFolder = folderPath
                folderCount += 1
                let depth = folderURL.pathComponents.count - rootDepth
                if depth <= 1 {
                    appendLog("Scanning \(folderURL.lastPathComponent)/  (\(totalCount) files so far)")
                }
            }

            // Type counts
            let ext = url.pathExtension.lowercased()
            if Self.rawExtensions.contains(ext)                { rawCount  += 1 }
            else if ["jpg","jpeg","heic","heif"].contains(ext)  { jpegCount += 1 }
            else                                                { otherCount += 1 }

            bytesFound  += fileSize
            totalCount  += 1
            scanProgress = min(0.95, Double(bytesFound) / Double(driveBytes))

            // Build and classify record
            let absPath  = url.path
            let relPath  = absPath.hasPrefix(mountPath)
                ? String(absPath.dropFirst(mountPath.count).drop(while: { $0 == "/" }))
                : absPath
            let modISO   = iso8601.string(from: modDate)
            let existing = existingByPath[relPath]

            if let e = existing, e.modifiedAt == modISO {
                // Unchanged — nothing to write
                skippedCount += 1
            } else {
                // New or modified — queue for write
                if let old = existing?.thumbnailPath, existing?.modifiedAt != modISO {
                    thumbsToDelete.append(old)
                }
                pendingBatch.append(DrivePhotoRecord(
                    id:               existing?.id ?? UUID().uuidString,
                    relativePath:     relPath,
                    filename:         url.lastPathComponent,
                    fileSize:         Int(fileSize),
                    captureDate:      existing?.captureDate,
                    width:            existing?.width,
                    height:           existing?.height,
                    isRaw:            Self.rawExtensions.contains(ext) ? 1 : 0,
                    thumbnailPath:    nil,
                    indexedAt:        iso8601.string(from: .now),
                    modifiedAt:       modISO,
                    duplicateGroupId: existing?.duplicateGroupId,
                    orientationDegrees: nil,
                    sceneLabel:         nil,
                    faceCount:          nil,
                    filmFrameCount:     nil,
                    workflowsRun:       nil
                ))
            }

            scannedCount   = totalCount
            currentFilename = url.lastPathComponent

            // Flush every 50 new/modified records — fires ValueObservation so the
            // grid populates while the scan is still running.
            if pendingBatch.count >= 50 {
                let batch = pendingBatch; pendingBatch = []
                try? await database.dbPool.write { db in
                    for r in batch { try r.upsert(db) }
                }
            }

            if totalCount % logEvery == 0 {
                appendLog("\(totalCount) files scanned · \(skippedCount) unchanged · " +
                          "\(Int(scanProgress * 100))% of drive")
            }
        }

        // Flush anything remaining (including when cancelled — keeps partial results)
        if !pendingBatch.isEmpty {
            let batch = pendingBatch
            try? await database.dbPool.write { db in
                for r in batch { try r.upsert(db) }
            }
        }

        // Delete stale thumbnails off the hot path
        let toDelete = thumbsToDelete
        Task.detached(priority: .background) {
            for path in toDelete { try? FileManager.default.removeItem(atPath: path) }
        }

        let newCount = totalCount - skippedCount
        appendLog("Scan \(cancelToken.isCancelled ? "stopped" : "complete"): " +
                  "\(totalCount) files · \(newCount) new · \(skippedCount) unchanged")

        if cancelToken.isCancelled {
            appendLog("Partial results are available — tap 'Generate Thumbnails' to preview what's indexed.")
            currentStage = .idle; currentFilename = ""; isScanning = false
            return
        }

        appendLog("Tip: press 'Generate Thumbnails' to create previews when ready.")

        // Duplicate detection
        currentStage = .detectingDuplicates
        currentFilename = ""
        appendLog("Running duplicate detection…")
        try? await database.markDuplicates()
        let dupCount = await database.duplicateCount()
        appendLog("Duplicates: \(dupCount) files in duplicate groups")

        let elapsed = Int(-startTime.timeIntervalSinceNow)
        let timeStr = elapsed >= 60 ? "\(elapsed/60)m \(elapsed%60)s" : "\(elapsed)s"
        appendLog("Done: \(totalCount) files indexed in \(timeStr)")
        currentStage    = .complete
        currentFilename = ""
        isScanning      = false
        scanProgress    = 1.0
    }

    func reset() {
        isScanning = false; scannedCount = 0; totalCount = 0; scanProgress = 0
        currentStage = .idle; currentFilename = ""; folderCount = 0
        rawCount = 0; jpegCount = 0; otherCount = 0; skippedCount = 0
        thumbnailsDone = 0; thumbnailsTotal = 0
        logLines = []
    }

    // MARK: - Logging

    private func appendLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)"
        print("[DriveIndex] \(message)")
        logLines.append(line)
        if logLines.count > 40 { logLines.removeFirst() }
    }

    // MARK: - Enumeration

    /// Returns an AsyncStream that yields image URLs from a background thread one-at-a-time.
    /// Each yield is a suspension point so the actor (and its 300ms polls) stay responsive.
    nonisolated private func enumerateStream(at root: URL) -> AsyncStream<(URL, Int64, Date)> {
        let rootPath = root.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continuation.finish(); return }

                for case let url as URL in enumerator {
                    guard !Task.isCancelled else { break }
                    guard url.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard Self.imageExtensions.contains(ext) else { continue }
                    let rv      = try? url.resourceValues(forKeys: Set(keys))
                    let size    = rv?.fileSize.map { Int64($0) } ?? 0
                    let modDate = rv?.contentModificationDate ?? .distantPast
                    continuation.yield((url, size, modDate))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Thumbnail generation + auto-orientation (on-demand, JPEG preferred over RAW)

    /// Public entry point — call this separately after indexing completes.
    /// Caller is responsible for passing the security-scoped mountPoint URL.
    func startThumbnailGeneration(
        mountPoint: URL,
        volumeUUID: String,
        database: DrivePreviewDatabase,
        cancelToken: DriveScanCancellationToken
    ) async {
        guard !isScanning else { return }  // don't overlap with full index
        let thumbsDir = DrivePreviewDatabase.thumbsURL(for: volumeUUID)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        currentStage = .generatingThumbnails
        scanProgress = 0
        thumbnailsDone = 0; thumbnailsTotal = 0
        await generateThumbnails(mountPoint: mountPoint, database: database,
                                  thumbsDir: thumbsDir, cancelToken: cancelToken)
        currentStage = cancelToken.isCancelled ? .idle : .complete
        scanProgress = 1.0
    }

    private func generateThumbnails(
        mountPoint: URL, database: DrivePreviewDatabase,
        thumbsDir: URL, cancelToken: DriveScanCancellationToken
    ) async {
        let needsThumbs: [DrivePhotoRecord] = (try? await database.dbPool.read { db in
            try DrivePhotoRecord.filter(Column("thumbnail_path") == nil).fetchAll(db)
        }) ?? []
        guard !needsThumbs.isEmpty else {
            appendLog("Thumbnails: all photos already have previews — nothing to do.")
            return
        }

        thumbnailsTotal = needsThumbs.count
        thumbnailsDone  = 0

        // Group by base name — prefer JPEG/HEIC over RAW within each group
        var groups: [String: [DrivePhotoRecord]] = [:]
        for r in needsThumbs {
            // Key = folder + stem (not just stem) so that IMG_0001 in 100CANON and 101CANON
            // are NOT collapsed into the same group. Two records sharing a key are genuine
            // RAW+JPEG siblings (same folder, same name, different extension).
            let base = (r.relativePath as NSString).deletingPathExtension.lowercased()
            groups[base, default: []].append(r)
        }

        let nonRawExts: Set<String> = ["jpg","jpeg","heic","heif","png","tif","tiff"]
        let workItems: [(source: DrivePhotoRecord, group: [DrivePhotoRecord])] = groups.values.map { group in
            let source = group.first(where: {
                nonRawExts.contains(($0.filename as NSString).pathExtension.lowercased())
            }) ?? group.first!
            return (source, group)
        }

        let total       = workItems.count
        let logInterval = max(1, total / 10)
        // Thumbnail decoding (especially HEIC) uses VideoToolbox which allocates
        // IOSurface-backed GPU buffers (~9 MB each). Too many concurrent workers exhaust
        // the shared GPU memory pool → kIOReturnNoMemory failures. Cap at 8.
        let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        appendLog("Thumbnail pass: \(needsThumbs.count) files → \(total) groups · \(workerCount) workers")

        // Result value passed back through the task group
        struct ThumbResult: Sendable {
            let sourceID: String
            let group: [DrivePhotoRecord]
            let thumbPath: String?
            let width: Int?
            let height: Int?
            let captureDate: String?
            let gpsLatitude: Double?
            let gpsLongitude: Double?
            let orientationDegrees: Int
            let sourceFilename: String
        }

        var thumbsDone   = 0
        var pendingWrites: [DrivePhotoRecord] = []
        var workIndex    = 0

        await withTaskGroup(of: ThumbResult?.self) { taskGroup in

            // Closure to enqueue the next work item
            func enqueueNext() {
                guard workIndex < workItems.count else { return }
                let item = workItems[workIndex]
                workIndex += 1
                let mp       = mountPoint
                let td       = thumbsDir
                taskGroup.addTask {
                    guard !cancelToken.isCancelled else { return nil }
                    let absURL    = item.source.absoluteURL(mountPoint: mp)
                    let thumbName = item.source.id + ".jpg"
                    let thumbURL  = td.appendingPathComponent(thumbName)

                    // Decode thumbnail in memory — no disk write yet.
                    let (cgImage, width, height, captureDate, gpsLat, gpsLon) = await Task.detached(priority: .userInitiated) {
                        DrivePreviewService.decodeThumbnailAndDate(from: absURL)
                    }.value

                    // Write proxy to disk. Orientation ML is a separate workflow step.
                    var thumbPath: String? = nil
                    var orientationDegrees = 0
                    if let cg = cgImage {
                        thumbPath = await Task.detached(priority: .userInitiated) {
                            DrivePreviewService.writeJPEG(cg, to: thumbURL)
                        }.value
                    }
                    return ThumbResult(
                        sourceID: item.source.id,
                        group: item.group, thumbPath: thumbPath,
                        width: width, height: height, captureDate: captureDate,
                        gpsLatitude: gpsLat, gpsLongitude: gpsLon,
                        orientationDegrees: orientationDegrees,
                        sourceFilename: item.source.filename
                    )
                }
            }

            // Seed initial batch
            for _ in 0..<min(workerCount, workItems.count) { enqueueNext() }

            // Drain completions and keep pipeline full
            while let result = await taskGroup.next() {
                enqueueNext()   // immediately replace the finished worker

                guard let r = result else { continue }

                for var rec in r.group {
                    rec.captureDate        = r.captureDate
                    rec.gpsLatitude        = r.gpsLatitude
                    rec.gpsLongitude       = r.gpsLongitude
                    rec.orientationDegrees = r.orientationDegrees
                    if rec.id == r.sourceID {
                        // Only the chosen source (JPEG preferred) gets the thumbnail.
                        // RAW siblings keep thumbnailPath = nil so they're hidden in
                        // the grid (allPhotosStream filters thumbnail_path IS NOT NULL).
                        rec.thumbnailPath = r.thumbPath
                        rec.width         = r.width
                        rec.height        = r.height
                        var ran = rec.completedWorkflows
                        ran.insert(DriveWorkflow.orientation.rawValue)
                        rec.workflowsRun = ran.sorted().joined(separator: ",")
                    }
                    pendingWrites.append(rec)
                }
                currentFilename = r.sourceFilename
                thumbsDone     += 1
                thumbnailsDone  = thumbsDone
                scanProgress    = Double(thumbsDone) / Double(total)

                // Batch-write every 100 records to reduce DB round-trips
                if pendingWrites.count >= 100 {
                    let batch = pendingWrites
                    pendingWrites = []
                    try? await database.dbPool.write { db in
                        for rec in batch { try rec.upsert(db) }
                    }
                }

                if thumbsDone % logInterval == 0 {
                    appendLog("Thumbnails \(Int(scanProgress*100))% — \(thumbsDone)/\(total) groups")
                }
            }

            // Final flush
            if !pendingWrites.isEmpty {
                let batch = pendingWrites
                try? await database.dbPool.write { db in
                    for rec in batch { try rec.upsert(db) }
                }
            }
        }
        appendLog("Thumbnails complete: \(thumbsDone) groups · orientation classified")
    }

    // MARK: - Thumbnail + EXIF (single source open, in-memory CGImage)

    /// Opens `source` once and returns a decoded CGImage + EXIF date + GPS without touching disk.
    /// The caller runs ML on the CGImage in memory, then fires off a background write —
    /// eliminating the write→read round-trip that the old path required.
    nonisolated private static func decodeThumbnailAndDate(
        from source: URL
    ) -> (cgImage: CGImage?, width: Int?, height: Int?, captureDate: String?, gpsLatitude: Double?, gpsLongitude: Double?) {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            return (nil, nil, nil, nil, nil, nil)
        }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]

        let captureDate: String? = {
            guard let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let raw  = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            guard let date = fmt.date(from: raw) else { return raw }
            return ISO8601DateFormatter().string(from: date)
        }()

        // GPS coordinates — kCGImagePropertyGPSDictionary uses String keys (not CFString) at runtime
        var gpsLatitude: Double? = nil
        var gpsLongitude: Double? = nil
        if let gpsDic = props?[kCGImagePropertyGPSDictionary] as? [String: Any] {
            let lat    = gpsDic[kCGImagePropertyGPSLatitude  as String] as? Double
            let latRef = gpsDic[kCGImagePropertyGPSLatitudeRef  as String] as? String
            let lon    = gpsDic[kCGImagePropertyGPSLongitude as String] as? Double
            let lonRef = gpsDic[kCGImagePropertyGPSLongitudeRef as String] as? String
            if let lat {
                gpsLatitude = (latRef == "S") ? -lat : lat
            }
            if let lon {
                gpsLongitude = (lonRef == "W") ? -lon : lon
            }
        }

        // 1600 px gives enough resolution to look sharp in the quick-look overlay and
        // in the inspector preview while staying well under 1 MB on disk as JPEG.
        let maxPx = 1600 as CFNumber

        // Pass 1 — fast: use the embedded thumbnail if one exists and is big enough.
        // Most JPEG/RAW files have no embedded thumb → ImageIO auto-creates one.
        // HEIC files from iPhones always have an embedded thumb, but it can be tiny
        // (90×120). Accept it only if the longest side is ≥ 400 px — enough for any
        // grid cell without paying the IOSurface cost of a full HEVC decode.
        let cheapOpts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize:            maxPx,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform:     true,
            kCGImageSourceShouldCacheImmediately:           false,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, cheapOpts as CFDictionary),
           max(cg.width, cg.height) >= 400 {
            return (cg, cg.width, cg.height, captureDate, gpsLatitude, gpsLongitude)
        }

        // Pass 2 — full decode: embedded thumb was absent or too small.
        // This goes through VideoToolbox for HEIC and allocates an IOSurface buffer,
        // so it's heavier — but workerCount is capped to prevent GPU memory exhaustion.
        let fullOpts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize:          maxPx,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceShouldCacheImmediately:         false,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, fullOpts as CFDictionary) {
            return (cg, cg.width, cg.height, captureDate, gpsLatitude, gpsLongitude)
        }

        // Pass 3 — software fallback: IOSurface pool exhausted (e00002c2).
        // CIImage with useSoftwareRenderer bypasses the GPU entirely, so this
        // succeeds even when concurrent workers have drained the IOSurface budget.
        guard let ci = CIImage(contentsOf: source) else {
            return (nil, nil, nil, captureDate, gpsLatitude, gpsLongitude)
        }
        let maxEdge = CGFloat(800)
        let scale   = min(maxEdge / ci.extent.width, maxEdge / ci.extent.height, 1.0)
        let scaled  = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let softCtx = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = softCtx.createCGImage(scaled, from: scaled.extent,
                                             format: .RGBA8,
                                             colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return (nil, nil, nil, captureDate, gpsLatitude, gpsLongitude)
        }
        return (cg, cg.width, cg.height, captureDate, gpsLatitude, gpsLongitude)
    }

    /// Encodes a CGImage to a JPEG file on disk.
    nonisolated private static func writeJPEG(_ cg: CGImage, to destination: URL) -> String? {
        // JPEG has no alpha channel. CGImageSourceCreateThumbnailAtIndex sometimes tags
        // decoded images as AlphaPremultipliedLast even for fully-opaque sources.
        // Writing those directly produces an unnecessary 4-channel JPEG and triggers
        // "saving opaque image with AlphaPremulLast" warnings from ImageIO. Flatten to
        // opaque RGB first.
        let target: CGImage
        let alpha = cg.alphaInfo
        if alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast {
            let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            target = ctx?.makeImage() ?? cg
        } else {
            target = cg
        }
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, target,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? destination.path : nil
    }
}
