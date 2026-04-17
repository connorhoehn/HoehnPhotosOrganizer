import Foundation
import ImageIO
import GRDB

// MARK: - ImageAdjustmentService

/// Applies non-destructive image adjustments to PhotoAssets by writing XMP sidecars
/// and logging every change to activity_log.
///
/// One XMP sidecar is written per photo, placed next to the source file with
/// the same basename and a `.xmp` extension. This is the Lightroom / Adobe Camera Raw
/// convention — Photoshop reads it automatically when you open the image.
///
/// Batch variant: pass multiple photos to apply the same set of adjustments to all.
actor ImageAdjustmentService {

    // MARK: - Apply

    /// Write adjustment XMP sidecar(s) for one or more photos, log each to activity_log.
    ///
    /// - Parameters:
    ///   - photos: One or more PhotoAssets to adjust. The source file must be accessible.
    ///   - adjustments: The ordered list of adjustments to encode.
    ///   - db: Live AppDatabase for activity log writes.
    /// - Returns: Count of photos successfully processed (failures are logged, not thrown).
    func applyAdjustments(
        to photos: [PhotoAsset],
        adjustments: [ImageAdjustment],
        db: AppDatabase
    ) async throws -> Int {
        let xmpService = XMPSidecarService()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var successCount = 0

        for photo in photos {
            let photoURL = URL(fileURLWithPath: photo.filePath)
            let sidecarURL = photoURL.deletingPathExtension().appendingPathExtension("xmp")

            do {
                // Write a .xmp sidecar next to the source file.
                // Camera Raw reads sidecars for TIFFs/JPEGs — embedded XMP is ignored by ACR.
                try xmpService.writeAdjustmentXMP(to: sidecarURL, adjustments: adjustments)

                // Log each adjustment as a separate activity entry
                let summaries = adjustments.map { $0.displaySummary }.joined(separator: "; ")
                let metadataJson = (try? String(data: encoder.encode(adjustments), encoding: .utf8)) ?? "[]"

                let activity = ActivityDB(
                    id: UUID().uuidString,
                    kind: "adjustment",
                    title: "Adjustments saved",
                    detail: "\(photo.canonicalName): \(summaries)",
                    photoId: photo.id,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )

                // Non-fatal DB write: XMP file is the authoritative record
                _ = metadataJson  // kept for future adjustment_log table
                try? await db.dbPool.write { db in
                    try activity.insert(db)
                }

                successCount += 1
            } catch {
                print("ImageAdjustmentService: failed for \(photo.canonicalName): \(error)")
            }
        }

        return successCount
    }

    // MARK: - Read

    /// Check whether a photo has Camera Raw adjustments — either embedded in the image
    /// or in a legacy .xmp sidecar.
    func sidecarStatus(for photo: PhotoAsset) -> XMPSidecarStatus {
        let photoURL = URL(fileURLWithPath: photo.filePath)
        let sidecarURL = photoURL.deletingPathExtension().appendingPathExtension("xmp")

        // Check for embedded XMP by inspecting image properties (kCGImagePropertyIPTCDictionary or raw XMP tag).
        // ImageIO exposes the XMP tag (700) as a raw Data value in image properties.
        var hasCameraRaw = false
        if let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let xmpRaw = props["{XMP}"] as? Data,
           let xmpString = String(data: xmpRaw, encoding: .utf8) {
            hasCameraRaw = xmpString.contains("crs:")
        }

        if hasCameraRaw {
            return XMPSidecarStatus(exists: true, sidecarURL: sidecarURL, hasCameraRaw: true)
        }

        // Fall back to checking for a legacy sidecar.
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return XMPSidecarStatus(exists: false, sidecarURL: sidecarURL, hasCameraRaw: false)
        }
        let content = (try? String(contentsOf: sidecarURL, encoding: .utf8)) ?? ""
        return XMPSidecarStatus(exists: true, sidecarURL: sidecarURL,
                                hasCameraRaw: content.contains("crs:"))
    }

    // MARK: - Remove

    /// Delete the XMP sidecar for a photo and log the removal to activity_log.
    func removeAdjustments(for photo: PhotoAsset, db: AppDatabase) async {
        let photoURL = URL(fileURLWithPath: photo.filePath)
        let sidecarURL = photoURL.deletingPathExtension().appendingPathExtension("xmp")

        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: sidecarURL)
            let activity = ActivityDB(
                id: UUID().uuidString,
                kind: "adjustment",
                title: "Adjustments removed",
                detail: "\(photo.canonicalName): XMP sidecar deleted",
                photoId: photo.id,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            try? await db.dbPool.write { db in
                try activity.insert(db)
            }
        } catch {
            print("ImageAdjustmentService: could not remove sidecar: \(error)")
        }
    }
}

// MARK: - XMPSidecarStatus

struct XMPSidecarStatus {
    let exists: Bool
    let sidecarURL: URL
    /// True if the sidecar contains Camera Raw (crs:) adjustment data.
    let hasCameraRaw: Bool

    var displayLabel: String {
        if !exists { return "No sidecar" }
        if hasCameraRaw { return "Adjustments saved" }
        return "Sidecar (no adjustments)"
    }
}
