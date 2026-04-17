import Foundation
import ImageIO
import GRDB
import os.log

// MARK: - DriveScanResult

/// Summary of a fast metadata-only scan of a mounted drive.
/// No pixel reads — only file system metadata and lightweight EXIF date extraction.
struct DriveScanResult: Sendable {
    /// All candidate photo files found on the drive.
    let files: [ScannedFile]
    /// Total byte count of all candidate files.
    let totalBytes: Int64
    /// Earliest capture/modified date found.
    let oldestDate: Date?
    /// Most recent capture/modified date found.
    let newestDate: Date?
    /// Breakdown of files per top-level folder (e.g. DCIM/100CANON, DCIM/101CANON).
    let folderBreakdown: [FolderGroup]
    /// Number of files that already exist in the main library (by filename+size match).
    let duplicateCount: Int
    /// IDs (filename+size hashes) of files already in the library.
    let duplicateFilenames: Set<String>

    var photoCount: Int { files.count }
    var newPhotoCount: Int { files.count - duplicateCount }

    /// Suggested job name derived from the date range (e.g. "March 2026" or "Mar 15–22, 2026").
    var suggestedJobName: String {
        let fmt = DateFormatter()
        guard let oldest = oldestDate, let newest = newestDate else {
            return "Import — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))"
        }
        let cal = Calendar.current
        if cal.isDate(oldest, equalTo: newest, toGranularity: .month) {
            // Same month
            fmt.dateFormat = "MMMM yyyy"
            return fmt.string(from: oldest)
        } else if cal.isDate(oldest, equalTo: newest, toGranularity: .year) {
            // Same year, different months
            let monthFmt = DateFormatter()
            monthFmt.dateFormat = "MMM"
            let yearFmt = DateFormatter()
            yearFmt.dateFormat = "yyyy"
            return "\(monthFmt.string(from: oldest))–\(monthFmt.string(from: newest)) \(yearFmt.string(from: oldest))"
        } else {
            fmt.dateFormat = "MMM yyyy"
            return "\(fmt.string(from: oldest)) – \(fmt.string(from: newest))"
        }
    }
}

// MARK: - ScannedFile

/// Lightweight metadata for a single candidate file. No pixel data loaded.
struct ScannedFile: Sendable, Identifiable {
    let id: String          // UUID
    let url: URL
    let relativePath: String
    let filename: String
    let fileSize: Int64
    let modifiedDate: Date
    let captureDate: Date?  // from EXIF DateTimeOriginal (quick read)
    let isRaw: Bool
    let folderName: String  // immediate parent folder name

    /// Key used for duplicate detection: lowercased filename + file size.
    var deduplicationKey: String {
        "\(filename.lowercased())|\(fileSize)"
    }
}

// MARK: - FolderGroup

/// Summary of files within a single folder on the drive.
struct FolderGroup: Identifiable, Sendable {
    let id: String       // folder relative path
    let name: String     // display name (last component)
    let photoCount: Int
    let totalBytes: Int64
}

// MARK: - DriveScanPreviewService

/// Actor that performs a fast metadata-only scan of a mounted drive.
/// Collects file names, sizes, modification dates, and optionally reads EXIF
/// DateTimeOriginal from JPEG/HEIC headers (very fast — no pixel decode).
actor DriveScanPreviewService {

    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "DriveScanPreview")

    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var scannedCount = 0
    private(set) var totalEstimate = 0

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif",
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        "raw", "rwl", "pef", "srw", "x3f", "3fr",
        "png", "tif", "tiff",
    ]

    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        "dng", "raw", "rwl", "pef", "srw", "x3f", "3fr",
    ]

    /// Performs a fast scan of the drive, then checks the main library DB for duplicates.
    /// Returns a DriveScanResult summarizing what's on the drive.
    func scan(
        mountPoint: URL,
        appDatabase: AppDatabase?,
        cancelToken: DriveScanCancellationToken
    ) async -> DriveScanResult {
        guard !isScanning else {
            return DriveScanResult(
                files: [], totalBytes: 0, oldestDate: nil, newestDate: nil,
                folderBreakdown: [], duplicateCount: 0, duplicateFilenames: []
            )
        }

        isScanning = true
        progress = 0
        scannedCount = 0
        totalEstimate = 0

        let mountPath = mountPoint.path
        var files: [ScannedFile] = []
        var totalBytes: Int64 = 0
        var oldestDate: Date?
        var newestDate: Date?
        var folderCounts: [String: (count: Int, bytes: Int64)] = [:]

        // Enumerate all image files on the drive
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        guard let enumerator else {
            isScanning = false
            return DriveScanResult(
                files: [], totalBytes: 0, oldestDate: nil, newestDate: nil,
                folderBreakdown: [], duplicateCount: 0, duplicateFilenames: []
            )
        }

        // Phase 1: Enumerate files and collect metadata
        for case let url as URL in enumerator {
            guard !cancelToken.isCancelled else { break }

            let ext = url.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { continue }

            let rv = try? url.resourceValues(forKeys: Set(keys))
            let fileSize = Int64(rv?.fileSize ?? 0)
            let modDate = rv?.contentModificationDate ?? .distantPast

            let absPath = url.path
            let relPath = absPath.hasPrefix(mountPath)
                ? String(absPath.dropFirst(mountPath.count).drop(while: { $0 == "/" }))
                : absPath

            let folderURL = url.deletingLastPathComponent()
            let folderRel = folderURL.path.hasPrefix(mountPath)
                ? String(folderURL.path.dropFirst(mountPath.count).drop(while: { $0 == "/" }))
                : folderURL.lastPathComponent
            let folderName = folderURL.lastPathComponent

            // Quick EXIF date read for JPEG/HEIC — no pixel decode
            let captureDate: Date? = Self.quickCaptureDate(from: url, ext: ext)

            let effectiveDate = captureDate ?? modDate
            if oldestDate == nil || effectiveDate < oldestDate! {
                oldestDate = effectiveDate
            }
            if newestDate == nil || effectiveDate > newestDate! {
                newestDate = effectiveDate
            }

            let isRaw = Self.rawExtensions.contains(ext)

            let file = ScannedFile(
                id: UUID().uuidString,
                url: url,
                relativePath: relPath,
                filename: url.lastPathComponent,
                fileSize: fileSize,
                modifiedDate: modDate,
                captureDate: captureDate,
                isRaw: isRaw,
                folderName: folderName
            )
            files.append(file)
            totalBytes += fileSize

            // Folder breakdown
            let folderKey = folderRel.isEmpty ? "/" : folderRel
            var entry = folderCounts[folderKey] ?? (count: 0, bytes: 0)
            entry.count += 1
            entry.bytes += fileSize
            folderCounts[folderKey] = entry

            scannedCount = files.count
            // Progress based on file count — estimate updates as we go
            if files.count % 100 == 0 {
                progress = min(0.8, Double(files.count) / max(1, Double(totalEstimate)))
            }
        }

        progress = 0.85

        // Build folder breakdown sorted by count descending
        let folders = folderCounts.map { key, value in
            FolderGroup(
                id: key,
                name: (key as NSString).lastPathComponent,
                photoCount: value.count,
                totalBytes: value.bytes
            )
        }.sorted { $0.photoCount > $1.photoCount }

        // Phase 2: Check library for duplicates (by filename + file_size)
        var duplicateFilenames: Set<String> = []
        var duplicateCount = 0

        if let db = appDatabase {
            progress = 0.90

            // Batch check: collect all (filename, size) pairs and query
            let pairs = files.map { ($0.filename, $0.fileSize) }

            // Check in batches of 200 to avoid huge SQL queries
            let batchSize = 200
            for batchStart in stride(from: 0, to: pairs.count, by: batchSize) {
                guard !cancelToken.isCancelled else { break }
                let batchEnd = min(batchStart + batchSize, pairs.count)
                let batch = Array(pairs[batchStart..<batchEnd])

                let existingNames: Set<String> = (try? await db.dbPool.read { dbConn in
                    // Build OR conditions for each (name, size) pair.
                    // Use LOWER() on canonical_name to match ScannedFile.deduplicationKey
                    // which lowercases the filename for case-insensitive comparison.
                    var conditions: [String] = []
                    var args: [DatabaseValueConvertible] = []
                    for (name, size) in batch {
                        conditions.append("(LOWER(canonical_name) = ? AND file_size = ?)")
                        args.append(name.lowercased())
                        args.append(Int(size))
                    }
                    let sql = """
                        SELECT DISTINCT LOWER(canonical_name) || '|' || CAST(file_size AS TEXT) as key
                        FROM photo_assets
                        WHERE \(conditions.joined(separator: " OR "))
                    """
                    return try Set(String.fetchAll(dbConn, sql: sql, arguments: StatementArguments(args)))
                }) ?? []

                for key in existingNames {
                    duplicateFilenames.insert(key)
                }
            }

            duplicateCount = files.filter { duplicateFilenames.contains($0.deduplicationKey) }.count
            logger.info("[DriveScan] Duplicate check complete: \(duplicateCount) duplicate(s) of \(files.count) total, \(files.count - duplicateCount) new")
        }

        logger.info("[DriveScan] Scan finished: \(files.count) files, \(duplicateCount) duplicates, \(files.count - duplicateCount) new")
        progress = 1.0
        isScanning = false

        return DriveScanResult(
            files: files,
            totalBytes: totalBytes,
            oldestDate: oldestDate,
            newestDate: newestDate,
            folderBreakdown: folders,
            duplicateCount: duplicateCount,
            duplicateFilenames: duplicateFilenames
        )
    }

    // MARK: - Quick EXIF date (no pixel decode)

    /// Reads only the EXIF DateTimeOriginal from image headers.
    /// For RAW files this is skipped (too slow) — we rely on file modification date.
    private nonisolated static func quickCaptureDate(from url: URL, ext: String) -> Date? {
        // Only read EXIF from JPEG/HEIC — RAW EXIF reading can be slow
        guard ["jpg", "jpeg", "heic", "heif", "dng"].contains(ext) else { return nil }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        guard let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        return exifDateFormatter.date(from: raw)
    }

    /// Shared date formatter for EXIF DateTimeOriginal parsing.
    /// Avoids allocating a new DateFormatter per file during scan.
    private static let exifDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return fmt
    }()
}
