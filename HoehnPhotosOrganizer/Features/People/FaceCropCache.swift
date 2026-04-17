import AppKit
import ImageIO

// MARK: - FaceCropCache

/// Global cache for cropped face thumbnails.
/// Avoids re-reading proxy JPEGs from disk and re-cropping on every scroll.
/// Also limits concurrency to avoid saturating the I/O queue when hundreds
/// of cells become visible at once.
final class FaceCropCache: Sendable {

    static let shared = FaceCropCache()

    /// NSCache is thread-safe. Stores cropped NSImage keyed by face embedding ID.
    private nonisolated(unsafe) let cache = NSCache<NSString, NSImage>()

    /// Limits concurrent disk reads + crop operations.
    private let semaphore = DispatchSemaphore(value: 6)

    private init() {
        // Allow ~200 face crops in memory (~80×80 JPEG ≈ 25 KB each → ~5 MB)
        cache.countLimit = 500
    }

    /// Returns a cached crop or loads it from disk, crops, caches, and returns it.
    /// Runs the heavy work on a detached task with concurrency throttling.
    func crop(id: String, proxyURL: URL, bbox: CGRect) async -> NSImage? {
        let key = id as NSString

        // Fast path: already cached
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Throttled load
        let img = await Task.detached(priority: .utility) { [semaphore] in
            semaphore.wait()
            defer { semaphore.signal() }

            // Downsampled read — we only need a small face crop, so request a
            // thumbnail from ImageIO at a reasonable max dimension instead of
            // decoding the full proxy (which can be 1600px+).
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]

            guard let src = CGImageSourceCreateWithURL(proxyURL as CFURL, thumbOpts as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary),
                  let cropped = FaceEmbeddingService.cropFace(from: cgImage, bbox: bbox) else {
                return nil as NSImage?
            }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }.value

        if let img {
            cache.setObject(img, forKey: key)
        }
        return img
    }

    /// Evict a specific entry (e.g. after re-indexing).
    func evict(id: String) {
        cache.removeObject(forKey: id as NSString)
    }

    /// Clear the entire cache (e.g. on memory warning or re-index).
    func evictAll() {
        cache.removeAllObjects()
    }
}
