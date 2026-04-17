import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Renders and manages thumbnail images for adjustment version snapshots.
/// Thumbnails are stored in ~/Library/Application Support/HoehnPhotosOrganizer/proxies/snapshots/
enum SnapshotThumbnailService {

    /// Target width for snapshot thumbnails (height is derived from aspect ratio).
    static let thumbnailWidth: CGFloat = 200

    /// JPEG compression quality for snapshot thumbnails.
    static let compressionQuality: CGFloat = 0.75

    // MARK: - Directory

    /// Returns the snapshot thumbnails directory, creating it if needed.
    static func snapshotThumbnailsDirectory() -> URL {
        let dir = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Render

    /// Renders the given preview NSImage down to a ~200px-wide JPEG thumbnail
    /// and writes it to disk.  Returns the absolute file path on success.
    ///
    /// - Parameters:
    ///   - previewImage: The current Develop preview (full resolution or proxy).
    ///   - snapshotId: The `AdjustmentSnapshot.id` — used to name the file.
    /// - Returns: The absolute path of the written JPEG, or `nil` on failure.
    static func renderThumbnail(from previewImage: NSImage, snapshotId: String) -> String? {
        let srcSize = previewImage.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        let scale = thumbnailWidth / srcSize.width
        let thumbW = Int(thumbnailWidth)
        let thumbH = Int(srcSize.height * scale)
        guard thumbW > 0, thumbH > 0 else { return nil }

        // Draw into a bitmap at the target size
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: thumbW,
            pixelsHigh: thumbH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = ctx
        ctx?.imageInterpolation = .high

        previewImage.draw(
            in: NSRect(x: 0, y: 0, width: thumbW, height: thumbH),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        // Write as JPEG
        guard let jpegData = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        ) else { return nil }

        let fileURL = snapshotThumbnailsDirectory()
            .appendingPathComponent("snapshot_\(snapshotId).jpg")

        do {
            try jpegData.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            print("[SnapshotThumbnailService] Failed to write thumbnail: \(error)")
            return nil
        }
    }

    // MARK: - Cleanup

    /// Deletes the thumbnail file for the given snapshot, if it exists.
    static func deleteThumbnail(atPath path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Deletes the thumbnail file for a snapshot by its ID (convention-based path).
    static func deleteThumbnail(forSnapshotId snapshotId: String) {
        let fileURL = snapshotThumbnailsDirectory()
            .appendingPathComponent("snapshot_\(snapshotId).jpg")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
