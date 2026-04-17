import Foundation
import HoehnPhotosCore

// MARK: - IngestionProgress

/// Progress snapshot emitted by IngestionActor during a scan.
struct IngestionProgress: Sendable {
    let totalFiles: Int
    let processedFiles: Int
    let failedFiles: Int
    let currentFile: String
}

// MARK: - IngestionActor

/// Swift actor that scans a mounted drive volume, creates PhotoAsset rows, extracts EXIF,
/// reverse-geocodes GPS coordinates, and advances each record through the ProcessingState
/// machine.
///
/// Resume safety (ING-4): files already past the initial `.indexed` state are skipped.
/// The skip check MUST use `photoRepo.fetchByCanonicalName(canonicalName)` — the
/// camera-assigned filename — and NOT `fetchById`. `fetchById` takes an internal UUID;
/// passing a canonical name to it always returns nil, silently breaking resume logic.
actor IngestionActor {
    private let photoRepo: PhotoRepository
    private let driveRepo: DriveRepository
    private let geocoder = GeocoderService()

    /// File extensions recognised as photo assets (from config.json supported_extensions).
    private static let supportedExtensions: Set<String> = [
        "dng", "cr3", "cr2", "arw", "nef", "orf", "raf", "rw2",
        "tif", "tiff", "jpg", "jpeg", "png", "heic", "psd"
    ]

    init(photoRepo: PhotoRepository, driveRepo: DriveRepository) {
        self.photoRepo = photoRepo
        self.driveRepo = driveRepo
    }

    // MARK: - RAW+JPG Deduplication

    struct DeduplicatedEntry {
        let url: URL
        let jpgCompanion: URL?
    }

    /// Filter a list of URLs to prefer RAW files over JPG companions with the same stem.
    static func deduplicateRawJpgPairs(_ urls: [URL]) -> [DeduplicatedEntry] {
        let rawExts: Set<String> = ["dng", "cr3", "cr2", "arw", "nef", "orf", "raf", "rw2", "raw", "rwl", "pef", "srw", "x3f", "3fr"]
        let jpgExts: Set<String> = ["jpg", "jpeg"]

        // Group by stem (filename without extension, lowercased)
        var byStem: [String: [URL]] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            byStem[stem, default: []].append(url)
        }

        var result: [DeduplicatedEntry] = []
        for (_, group) in byStem {
            let raws = group.filter { rawExts.contains($0.pathExtension.lowercased()) }
            let jpgs = group.filter { jpgExts.contains($0.pathExtension.lowercased()) }
            let others = group.filter { !rawExts.contains($0.pathExtension.lowercased()) && !jpgExts.contains($0.pathExtension.lowercased()) }

            if let raw = raws.first {
                // Prefer RAW, attach JPG as companion for EXIF fallback
                result.append(DeduplicatedEntry(url: raw, jpgCompanion: jpgs.first))
                // Include additional RAWs if multiple
                for extra in raws.dropFirst() {
                    result.append(DeduplicatedEntry(url: extra, jpgCompanion: nil))
                }
                // Skip JPGs — they're duplicates of the RAW
            } else {
                // No RAW — include all JPGs and others
                for url in jpgs + others {
                    result.append(DeduplicatedEntry(url: url, jpgCompanion: nil))
                }
            }
        }

        return result.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    // MARK: - Public API

    /// Begins ingestion of the given drive volume and returns an AsyncStream of progress.
    ///
    /// The stream yields an IngestionProgress snapshot for each file processed and
    /// finishes with a final "Complete" snapshot when the whole volume has been scanned.
    ///
    /// Marked `nonisolated` so callers outside the actor can create the stream without
    /// awaiting actor entry. The actual scan runs inside the actor via the inner Task.
    nonisolated func startIngestion(drive: DriveInfo) -> AsyncStream<IngestionProgress> {
        AsyncStream { continuation in
            Task {
                await self.runIngestion(drive: drive, continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Core ingestion loop

    private func runIngestion(
        drive: DriveInfo,
        continuation: AsyncStream<IngestionProgress>.Continuation
    ) async {
        // Upsert the drive inventory row, updating last_seen timestamp.
        await upsertDriveRecord(drive: drive)

        // Enumerate all supported photo files on the volume.
        let files = enumerateFiles(at: drive.mountPoint)
        let total = files.count
        var processed = 0
        var failed = 0

        for url in files {
            let canonicalName = url.lastPathComponent

            // Emit current-file progress before processing so the UI shows the filename.
            continuation.yield(IngestionProgress(
                totalFiles: total,
                processedFiles: processed,
                failedFiles: failed,
                currentFile: canonicalName
            ))

            // ING-4: Resume skip — use fetchByCanonicalName, NOT fetchById.
            // fetchById takes a UUID; passing canonicalName would always return nil,
            // silently breaking resume.
            if let existing = try? await photoRepo.fetchByCanonicalName(canonicalName),
               existing.processingState != ProcessingState.indexed.rawValue {
                // Already processed past initial indexed state — skip.
                processed += 1
                continue
            }

            // Resolve file size.
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = attrs?.fileSize ?? 0

            // Build relative path by stripping the mount point prefix.
            let relativePath: String
            if url.path.hasPrefix(drive.mountPoint.path) {
                relativePath = String(url.path.dropFirst(drive.mountPoint.path.count))
            } else {
                relativePath = url.path
            }

            // Create new PhotoAsset (initial state = .indexed).
            var asset = PhotoAsset.new(
                canonicalName: canonicalName,
                role: .original,
                filePath: relativePath,
                fileSize: fileSize
            )

            do {
                // -- EXIF extraction --
                let exif = EXIFExtractor.extract(url: url)
                if let exifStr = encodeEXIF(exif) {
                    asset.rawExifJson = exifStr
                }

                // -- Geocode + time-of-day derived metadata --
                var derived: [String: String] = [:]
                if let lat = exif.latitude, let lon = exif.longitude {
                    if let location = try? await geocoder.reverseGeocode(latitude: lat, longitude: lon) {
                        if !location.city.isEmpty    { derived["city"]    = location.city }
                        if !location.country.isEmpty { derived["country"] = location.country }
                        if !location.region.isEmpty  { derived["region"]  = location.region }
                    }
                    if let captureDate = exif.captureDate {
                        derived["timeOfDay"] = TimeOfDayService.classify(
                            captureDate: captureDate,
                            latitude: lat
                        ).rawValue
                    }
                }
                if !derived.isEmpty, let metaStr = encodeDict(derived) {
                    asset.userMetadataJson = metaStr
                }

                // Advance: indexed → proxyPending (EXIF stored, geocode attempted).
                asset.processingState = ProcessingState.proxyPending.rawValue
                try await photoRepo.upsert(asset)

                processed += 1
            } catch {
                // ING-8: Per-file failure — record error_message but continue the batch.
                asset.errorMessage = error.localizedDescription
                try? await photoRepo.upsert(asset)
                failed += 1
            }
        }

        // Final completion snapshot.
        continuation.yield(IngestionProgress(
            totalFiles: total,
            processedFiles: processed,
            failedFiles: failed,
            currentFile: "Complete"
        ))
    }

    // MARK: - Drive inventory

    private func upsertDriveRecord(drive: DriveInfo) async {
        let now = ISO8601DateFormatter().string(from: .now)
        // Clean up pre-Phase-14 rows that used random UUIDs instead of volume UUID
        if let existing = try? await driveRepo.fetchByVolumeLabel(drive.volumeLabel),
           existing.id != drive.volumeUUID {
            try? await driveRepo.delete(id: existing.id)
        }
        let existing = try? await driveRepo.fetchByVolumeLabel(drive.volumeLabel)
        let driveDB = DriveDB(
            id: drive.volumeUUID,
            volumeLabel: drive.volumeLabel,
            mountPoint: drive.mountPoint.path,
            totalBytes: drive.totalBytes,
            freeBytes: drive.freeBytes,
            lastSeen: now,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try? await driveRepo.upsert(driveDB)
    }

    // MARK: - File enumeration

    private func enumerateFiles(at mountPoint: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Serialisation helpers

    private func encodeEXIF(_ exif: EXIFSnapshot) -> String? {
        let codable = exif.asCodable()
        guard let data = try? JSONEncoder().encode(codable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeDict(_ dict: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

